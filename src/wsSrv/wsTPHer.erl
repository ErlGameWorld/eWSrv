-module(wsTPHer).
-include("wsCom.hrl").
-include_lib("kernel/include/file.hrl").
-export([handle/3, init/1, handleWs/3, supportedProtocols/0, supportedExtensions/0]).

init(_Args) ->
	{ok, []}.

handle(Method, Path, WsReq) ->
	doHandle(Method, Path, WsReq).

%% 主要的请求处理函数
%% 主路由

doHandle('GET', <<"/">>, _WsReq) ->
	FilePath = filename:join([code:priv_dir(eWSrv), "test.html"]),
	case file:read_file(FilePath, [raw]) of
		{ok, TestHtml} ->
			{ok, [{<<"Content-Type">>, <<"text/html">>}], TestHtml};
		{error, _} ->
			Msg = <<"Welcome to eWSrv!">>,
			{ok, [{<<"Content-Type">>, <<"text/plain">>}], Msg}
	end;

doHandle('GET', <<"/ip">>, WsReq) ->
	#wsReq{socket = Socket} = WsReq,
	case wsNet:peername(Socket) of
		{ok, {IP, Port}} ->
			{A, B, C, D} = IP,
			Msg = iolist_to_binary([
				<<"Your IP: ">>, integer_to_binary(A), <<".">>,
				integer_to_binary(B), <<".">>,
				integer_to_binary(C), <<".">>,
				integer_to_binary(D), <<":">>,
				integer_to_binary(Port)
			]),
			{ok, [{<<"Content-Type">>, <<"text/plain">>}], Msg};
		{error, _} ->
			{ok, [{<<"Content-Type">>, <<"text/plain">>}], <<"Unable to get peer info">>}
	end;

doHandle('GET', <<"/html">>, _WsReq) ->
	FilePath = filename:join([code:priv_dir(eWSrv), "test.html"]),
	case file:read_file(FilePath, [raw]) of
		{ok, TestHtml} ->
			{ok, [{<<"Content-Type">>, <<"text/html">>}], TestHtml};
		{error, _} ->
			Msg = <<"Welcome to eWSrv!">>,
			{ok, [{<<"Content-Type">>, <<"text/plain">>}], Msg}
	end;

%% HTTP/2 专项浏览器测试页。浏览器侧请使用 HTTPS + ALPN h2。
doHandle('GET', <<"/http2">>, _WsReq) ->
	FilePath = filename:join([code:priv_dir(eWSrv), "http2-test.html"]),
	case file:read_file(FilePath, [raw]) of
		{ok, Html} ->
			{ok, [{<<"Content-Type">>, <<"text/html; charset=utf-8">>}], Html};
		{error, Reason} ->
			{500, [{<<"Content-Type">>, <<"text/plain">>}],
				iolist_to_binary(io_lib:format("HTTP/2 test page error: ~p", [Reason]))}
	end;

%% 返回服务端实际看到的协议版本，配合浏览器 Performance API 双重确认 h2。
doHandle('GET', <<"/h2/info">>, #wsReq{version = Version, scheme = Scheme} = _WsReq) ->
	Json = iolist_to_binary([
		<<"{\"server\":\"eWSrv\",\"version\":\"">>, versionBin(Version),
		<<"\",\"scheme\":\"">>, schemeBin(Scheme), <<"\"}">>
	]),
	{ok, [
		{<<"Content-Type">>, <<"application/json">>},
		{<<"Cache-Control">>, <<"no-store">>}
	], Json};

%% 延迟响应用于验证同一 HTTP/2 connection 上多个 stream 是否真正并行。
doHandle('GET', <<"/h2/delay/", DelayBin/binary>>, _WsReq) ->
	case boundedInt(DelayBin, 0, 5000) of
		{ok, Delay} ->
			timer:sleep(Delay),
			{ok, [{<<"Content-Type">>, <<"text/plain">>}],
				iolist_to_binary([<<"delay ">>, integer_to_binary(Delay), <<" ms">>])};
		error ->
			{400, [], <<"delay must be 0..5000 ms">>}
	end;

%% 动态大响应，用于 DATA frame / flow-control / throughput 测试。
doHandle('GET', <<"/h2/bytes/", SizeBin/binary>>, _WsReq) ->
	case boundedInt(SizeBin, 0, 64 * 1024 * 1024) of
		{ok, Size} ->
			{ok, [
				{<<"Content-Type">>, <<"application/octet-stream">>},
				{<<"Cache-Control">>, <<"no-store">>}
			], binary:copy(<<$x>>, Size)};
		error ->
			{400, [], <<"size must be 0..67108864 bytes">>}
	end;

doHandle('GET', <<"/status/", Code/binary>>, _WsReq) ->
	{binary_to_integer(Code), [{<<"Content-Type">>, <<"text/plain">>}], wsHttp:status(binary_to_integer(Code))};

doHandle('GET', <<"/hello">>, _WsReq) ->
	{ok, [{<<"Content-Type">>, <<"text/plain">>}], <<"Hello, World!">>};

doHandle('GET', <<"/error">>, _WsReq) ->
	{500, [], <<"Internal Server Error">>};

doHandle('GET', <<"/crash">>, _WsReq) ->
	erlang:error(intentional_crash);

doHandle('GET', <<"/timeout">>, _WsReq) ->
	timer:sleep(60000),  % 60秒超时
	{ok, [], <<"This should timeout">>};

doHandle('GET', <<"/json">>, _WsReq) ->
	Json = <<"{\"message\": \"Hello, JSON!\", \"timestamp\": ">>,
	Ts = integer_to_binary(erlang:system_time(second)),
	Json2 = <<Json/binary, Ts/binary, "}">>,
	{ok, [{<<"Content-Type">>, <<"application/json">>}], Json2};

doHandle('GET', <<"/compressed">>, _WsReq) ->
	%% 生成一个较大的响应体以测试压缩效果
	Body = binary:copy(<<"Hello World!">>, 86),
	{ok, [{<<"Content-Type">>, <<"text/plain">>}], Body};

doHandle('GET', <<"/params">>, WsReq) ->
	#wsReq{args = Args} = WsReq,
	Formatted = formatArgs(Args),
	Resp = iolist_to_binary([<<"Query parameters:\n">>, Formatted]),
	{ok, [{<<"Content-Type">>, <<"text/plain">>}], Resp};

doHandle('GET', <<"/headers">>, WsReq) ->
	#wsReq{headers = Headers} = WsReq,
	Lines = <<<<(wsHttp:toBinStr(Name))/binary, ": ", (wsHttp:toBinStr(Value))/binary, "\n">> || {Name, Value} <- Headers>>,
	Resp = iolist_to_binary([<<"Request headers:\n">>, Lines]),
	{ok, [{<<"Content-Type">>, <<"text/plain">>}], Resp};

doHandle('GET', <<"/stream">>, _WsReq) ->
	Self = self(),
	spawn(fun() ->
		Self ! {chunk, <<"Stream started\n">>},
		timer:sleep(1000),
		Self ! {chunk, <<"part-1\n">>},
		timer:sleep(1000),
		Self ! {chunk, <<"part-2\n">>},
		timer:sleep(1000),
		Self ! {chunk, <<"part-3\n">>},
		Self ! {chunk, close}
		  end),
	Headers = [
		{<<"Content-Type">>, <<"text/plain">>},
		{<<"X-Stream">>, <<"true">>}
	],
	{chunk, Headers};

doHandle('GET', <<"/chunk">>, _WsReq) ->
	scheduleChunks(self()),
	Headers = [
		{<<"Content-Type">>, <<"text/plain">>},
		{<<"Transfer-Encoding">>, <<"chunked">>}
	],
	{chunk, Headers};

doHandle('GET', <<"/file">>, _WsReq) ->
	FilePath = filename:join([code:priv_dir(eWSrv), "server_cert.pem"]),
	case file:read_file(FilePath, [raw]) of
		{ok, Data} ->
			{ok, [
				{<<"Content-Type">>, <<"application/x-pem-file">>},
				{<<"Content-Disposition">>, <<"attachment; filename=server_cert.pem">>}
			], Data};
		{error, Reason} ->
			Err = io_lib:format("Failed to read file: ~p", [Reason]),
			{500, [{<<"Content-Type">>, <<"text/plain">>}], list_to_binary(Err)}
	end;

doHandle('GET', <<"/range">>, WsReq) ->
	#wsReq{headers = Headers} = WsReq,
	FilePath = filename:join([code:priv_dir(eWSrv), "server_cert.pem"]),
	case file:read_file(FilePath) of
		{ok, Data} ->
			Total = byte_size(Data),
			case parseRangeHeader(Headers) of
				{Start, undefined} when Start < Total ->
					Slice = binary:part(Data, Start, Total - Start),
					{206, [
						{<<"Content-Range">>, iolist_to_binary([<<"bytes ">>, integer_to_binary(Start), <<"-">>, integer_to_binary(Total - 1), <<"/">>, integer_to_binary(Total)])}
					], Slice};
				{Start, End} when Start < Total, End < Total, End >= Start ->
					Length = End - Start + 1,
					Slice = binary:part(Data, Start, Length),
					{206, [
						{<<"Content-Range">>, iolist_to_binary([<<"bytes ">>, integer_to_binary(Start), <<"-">>, integer_to_binary(End), <<"/">>, integer_to_binary(Total)])}
					], Slice};
				invalid_range ->
					{416, [{<<"Content-Range">>, iolist_to_binary([<<"bytes */">>, integer_to_binary(Total)])}], <<>>};
				undefined ->
					{200, [], Data}
			end;
		{error, Reason} ->
			Err = io_lib:format("Failed to read file: ~p", [Reason]),
			{500, [{<<"Content-Type">>, <<"text/plain">>}], list_to_binary(Err)}
	end;

doHandle('GET', <<"/cache">>, WsReq) ->
	#wsReq{headers = Headers} = WsReq,
	FilePath = filename:join([code:priv_dir(eWSrv), "server_cert.pem"]),
	case file:read_file_info(FilePath) of
		{ok, #file_info{mtime = MTime, size = Size}} ->
			LastModified = format_rfc1123(MTime),
			TS = calendar:datetime_to_gregorian_seconds(MTime),
			ETag = iolist_to_binary([<<"\"">>, integer_to_binary(Size), <<"-">>, integer_to_binary(TS), <<"\"">>]),
			CacheCtl = <<"public, max-age=60">>,
			IfNoneMatch = wsUtil:getHeader('If-None-Match', Headers, undefined),
			IfModSince = wsUtil:getHeader('If-Modified-Since', Headers, undefined),
			CommonHeaders = [
				{<<"ETag">>, ETag},
				{<<"Cache-Control">>, CacheCtl},
				{<<"Last-Modified">>, LastModified},
				{<<"Content-Type">>, <<"text/plain">>}
			],
			case {IfNoneMatch, IfModSince} of
				{ETag, _} -> {304, CommonHeaders, <<>>};
				{_, LastModified} -> {304, CommonHeaders, <<>>};
				_ -> {ok, CommonHeaders, <<"Cache test content">>}
			end;
		{error, Reason} ->
			Err = io_lib:format("Failed to stat file: ~p", [Reason]),
			{500, [{<<"Content-Type">>, <<"text/plain">>}], list_to_binary(Err)}
	end;

doHandle('GET', <<"/redirect">>, _WsReq) ->
	{301, [{<<"Location">>, <<"/">>}], <<"Redirecting to /">>};

doHandle('POST', <<"/echo">>, WsReq) ->
	#wsReq{body = Body} = WsReq,
	{ok, [{<<"Content-Type">>, <<"text/plain">>}], Body};

doHandle('POST', <<"/upload">>, WsReq) ->
	#wsReq{body = Body, headers = Headers} = WsReq,
	ContentType = wsUtil:getHeader('Content-Type', Headers, <<"">>),
	case binary:match(ContentType, <<"multipart/form-data">>) of
		{_, _} ->
			Size = byte_size(Body),
			Response = iolist_to_binary([<<"Upload received, size: ">>, integer_to_binary(Size), <<" bytes">>]),
			{ok, [{<<"Content-Type">>, <<"text/plain">>}], Response};
		nomatch ->
			{400, [], <<"Expected multipart/form-data content type">>}
	end;

doHandle('POST', <<"/form">>, WsReq) ->
	#wsReq{body = Body} = WsReq,
	Pairs = parseFormData(Body),
	Resp = iolist_to_binary([<<"Form received:\n">>, [[K, <<"=">>, V, <<"\n">>] || {K, V} <- Pairs]]),
	{ok, [{<<"Content-Type">>, <<"text/plain">>}], Resp};

doHandle('POST', <<"/json">>, WsReq) ->
	#wsReq{body = Body} = WsReq,
	Resp = iolist_to_binary([<<"Received JSON body of size ">>, integer_to_binary(byte_size(Body))]),
	{ok, [{<<"Content-Type">>, <<"application/json">>}], Resp};

doHandle('PUT', <<"/resource/", Id/binary>>, WsReq) ->
	#wsReq{headers = Headers, body = Body} = WsReq,
	Size = integer_to_binary(byte_size(Body)),
	Resp = iolist_to_binary([<<"PUT resource ">>, Id, <<" with ">>, Size, <<" bytes\nHeaders:\n">>, [[wsHttp:toBinStr(N), <<": ">>, wsHttp:toBinStr(V), <<"\n">>] || {N, V} <- Headers]]),
	{ok, [{<<"Content-Type">>, <<"text/plain">>}], Resp};

doHandle('PATCH', <<"/resource/", Id/binary>>, WsReq) ->
	#wsReq{body = Body} = WsReq,
	Size = integer_to_binary(byte_size(Body)),
	Json = list_to_binary(io_lib:format("{\"id\": \"~s\", \"updated\": true, \"bytes\": ~s}", [Id, Size])),
	{ok, [{<<"Content-Type">>, <<"application/json">>}], Json};

doHandle('PUT', Path, WsReq) ->
	#wsReq{body = Body} = WsReq,
	Response = iolist_to_binary([<<"PUT to ">>, Path, <<", body size: ">>, integer_to_binary(byte_size(Body))]),
	{ok, [], Response};

doHandle('DELETE', <<"/resource/", Id/binary>>, _WsReq) ->
	Json = list_to_binary(io_lib:format("{\"id\": \"~s\", \"deleted\": true}", [Id])),
	{ok, [{<<"Content-Type">>, <<"application/json">>}], Json};

doHandle('DELETE', Path, _WsReq) ->
	Response = iolist_to_binary([<<"DELETE request for: ">>, Path]),
	{ok, [{<<"Content-Type">>, <<"text/plain">>}], Response};

doHandle('HEAD', <<"/resource/", Id/binary>>, _WsReq) ->
	Json = list_to_binary(io_lib:format("{\"id\": \"~s\", \"exists\": true, \"size\": 1024}", [Id])),
	{ok, [{<<"Content-Type">>, <<"application/json">>}], Json};

doHandle('HEAD', <<"/stream">>, _WsReq) ->
	{ok, [
		{<<"Content-Type">>, <<"text/plain">>},
		{<<"X-Stream">>, <<"true">>}
	], <<>>};

doHandle('HEAD', <<"/chunk">>, _WsReq) ->
	{ok, [
		{<<"Content-Type">>, <<"text/plain">>},
		{<<"Transfer-Encoding">>, <<"chunked">>}
	], <<>>};

doHandle('HEAD', Path, WsReq) ->
	case doHandle('GET', Path, WsReq) of
		{ok, Headers, _Body} ->
			{ok, Headers, _Body};
		{error, Status, Headers, _Body} ->
			{Status, Headers, _Body};
		{Code, Headers, _Body} ->
			{Code, Headers, _Body}
	end;

doHandle('OPTIONS', <<"/api/", _/binary>>, _WsReq) ->
	Headers = [
		{<<"Access-Control-Allow-Origin">>, <<"*">>},
		{<<"Access-Control-Allow-Methods">>, <<"GET, POST, PUT, DELETE, HEAD, OPTIONS">>},
		{<<"Access-Control-Allow-Headers">>, <<"Content-Type, Authorization">>},
		{<<"Access-Control-Max-Age">>, <<"86400">>}
	],
	{ok, Headers, <<"">>};

doHandle('OPTIONS', Path, _WsReq) ->
	Methods = case Path of
				  <<"/resource/", _Id/binary>> -> [<<"GET">>, <<"PUT">>, <<"DELETE">>, <<"HEAD">>, <<"OPTIONS">>];
				  _ -> [<<"GET">>, <<"POST">>, <<"HEAD">>, <<"OPTIONS">>]
			  end,
	Allow = iolist_to_binary(lists:join(<<", ">>, Methods)),
	{ok, [
		{<<"Allow">>, Allow},
		{<<"Access-Control-Allow-Methods">>, Allow},
		{<<"Access-Control-Allow-Headers">>, <<"Content-Type, Authorization">>},
		{<<"Access-Control-Max-Age">>, <<"86400">>}
	], <<>>};

doHandle('GET', <<"/api/test">>, WsReq) ->
	#wsReq{headers = Headers} = WsReq,
	Origin = wsUtil:getHeader('Origin', Headers, <<"*">>),
	Resp = iolist_to_binary([<<"CORS GET OK">>]),
	{ok, [
		{<<"Access-Control-Allow-Origin">>, Origin},
		{<<"Vary">>, <<"Origin">>},
		{<<"Content-Type">>, <<"text/plain">>}
	], Resp};

doHandle('POST', <<"/api/data">>, WsReq) ->
	#wsReq{headers = Headers, body = Body} = WsReq,
	Origin = wsUtil:getHeader('Origin', Headers, <<"*">>),
	Len = integer_to_binary(byte_size(Body)),
	Json = list_to_binary(io_lib:format('{"ok":true,"bytes":~s}', [Len])),
	{ok, [
		{<<"Access-Control-Allow-Origin">>, Origin},
		{<<"Access-Control-Allow-Headers">>, <<"Content-Type, Authorization">>},
		{<<"Access-Control-Allow-Methods">>, <<"GET, POST, OPTIONS">>},
		{<<"Vary">>, <<"Origin">>},
		{<<"Content-Type">>, <<"application/json">>}
	], Json};

doHandle('GET', <<"/ws">>, WsReq) ->
	%% 检查是否为WebSocket升级请求
	case wsWebSocket:tryWsUpgrade(WsReq) of
		{ok, Headers} ->
			{wsUpgrade, Headers};
		{error, Reason} ->
			%% 返回普通的HTTP响应
			{502, [], Reason}
	end;

doHandle(_Method, _Path, _WsReq) ->
	{404, [], <<"Not Found">>}.

%% 辅助函数
versionBin({Major, Minor}) ->
	[integer_to_binary(Major), <<".">>, integer_to_binary(Minor)];
versionBin(Other) ->
	io_lib:format("~p", [Other]).

schemeBin(undefined) -> <<"undefined">>;
schemeBin(Scheme) when is_binary(Scheme) -> Scheme;
schemeBin(Scheme) when is_atom(Scheme) -> atom_to_binary(Scheme, utf8);
schemeBin(Scheme) -> iolist_to_binary(io_lib:format("~p", [Scheme])).

boundedInt(Bin, Min, Max) ->
	try binary_to_integer(Bin) of
		N when N >= Min, N =< Max -> {ok, N};
		_ -> error
	catch
		_:_ -> error
	end.

formatValue(Value) when is_binary(Value) -> Value;
formatValue(Value) when is_list(Value) -> list_to_binary(Value);
formatValue(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
formatValue(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).

parseFormData(Body) ->
	Pairs = binary:split(Body, <<"&">>, [global]),
	lists:map(fun(Pair) ->
		case binary:split(Pair, <<"=">>) of
			[Key, Value] -> {Key, Value};
			[Key] -> {Key, <<"">>}
		end
			  end, Pairs).

formatArgs(Args) ->
	lists:map(fun formatArg/1, Args).

formatArg({Key, Value}) ->
	[Key, <<" = ">>, formatValue(Value), <<"\n">>].

parseRangeHeader(Headers) ->
	case wsUtil:getHeader('Range', Headers, undefined) of
		undefined -> undefined;
		RangeBin -> parseRangeValue(RangeBin)
	end.

parseRangeValue(RangeBin) ->
	case binary:split(RangeBin, <<"=">>) of
		[<<"bytes">>, RangePart] ->
			case binary:split(RangePart, <<"-">>) of
				[StartBin, EndBin] ->
					try
						Start = binary_to_integer(StartBin),
						End = case EndBin of
								  <<"">> -> undefined;
								  _ -> binary_to_integer(EndBin)
							  end,
						{Start, End}
					catch _:_ -> invalid_range
					end;
				_ -> invalid_range
			end;
		_ -> invalid_range
	end.

scheduleChunks(Self) ->
	spawn(fun() ->
		lists:foreach(
			fun(I) ->
				timer:sleep(1000),
				Self ! {chunk, [<<"chunk-">>, integer_to_binary(I), <<"\n">>]}
			end,
			lists:seq(2, 5)
		),
		Self ! {chunk, close}
		  end).

%% ======= 工具函数：RFC1123 日期格式 =======
fmt2(N) -> list_to_binary(io_lib:format("~2..0B", [N])).
fmt4(N) -> list_to_binary(io_lib:format("~4..0B", [N])).

weekday(1) -> <<"Mon">>;
weekday(2) -> <<"Tue">>;
weekday(3) -> <<"Wed">>;
weekday(4) -> <<"Thu">>;
weekday(5) -> <<"Fri">>;
weekday(6) -> <<"Sat">>;
weekday(7) -> <<"Sun">>.

month(1) -> <<"Jan">>;
month(2) -> <<"Feb">>;
month(3) -> <<"Mar">>;
month(4) -> <<"Apr">>;
month(5) -> <<"May">>;
month(6) -> <<"Jun">>;
month(7) -> <<"Jul">>;
month(8) -> <<"Aug">>;
month(9) -> <<"Sep">>;
month(10) -> <<"Oct">>;
month(11) -> <<"Nov">>;
month(12) -> <<"Dec">>.

format_rfc1123({{Y, M, D}, {H, Min, S}}) ->
	W = calendar:day_of_the_week({Y, M, D}),
	iolist_to_binary([
		weekday(W), <<", ">>, fmt2(D), <<" ">>, month(M), <<" ">>, fmt4(Y), <<" ">>,
		fmt2(H), <<":">>, fmt2(Min), <<":">>, fmt2(S), <<" GMT">>
	]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% close(Socket) ->
% 	wsendFrame(Socket, ?WsOpClose, <<1000, "Normal closure">>).

handleWs(OpCode, Payload, WebState) ->
	doHandleWs(OpCode, Payload, WebState).

%% @doc 处理WebSocket消息
doHandleWs(?WsOpText, Message, WebState) ->
	%% 记录消息时间
	Now = erlang:system_time(millisecond),
	ClientId = 1, Count = 1,
	%% 处理不同类型的消息
	Response = case binary:split(Message, <<":">>) of
				   [<<"echo">>, EchoMsg] ->
					   iolist_to_binary([<<"Echo: ">>, EchoMsg]);
				   [<<"time">>] ->
					   Timestamp = integer_to_binary(Now),
					   iolist_to_binary([<<"Server time: ">>, Timestamp]);
				   [<<"count">>] ->
					   CountMsg = integer_to_binary(Count + 1),
					   iolist_to_binary([<<"Message count: ">>, CountMsg]);
				   [<<"chat">>, ChatMsg] ->
					   iolist_to_binary([ClientId, <<": ">>, ChatMsg]);
				   _ ->
					   Message
			   end,
	{ok, ?WsOpText, Response, WebState};

doHandleWs(?WsOpBinary, Data, WebState) ->
	%% 处理二进制消息
	Response = <<"Binary data received, length: ", (integer_to_binary(byte_size(Data)))/binary>>,
	{ok, ?WsOpBinary, Response, WebState};

doHandleWs(?WsOpClose, _Data, WebState) ->
	{close, WebState};

%% @doc 处理WebSocket Ping消息
doHandleWs(?WsOpPing, _Data, WebState) ->
	%% 自动回复Pong
	self() ! {ping, <<"pong">>},
	{ok, ?WsOpPing, <<"pong">>, WebState};

doHandleWs(?WsOpPong, _Data, WebState) ->
	{ok, WebState};

doHandleWs(_OpCode, _Data, WebState) ->
	{ok, WebState}.

%% @doc 返回支持的WebSocket协议
-spec supportedProtocols() -> [binary()].
supportedProtocols() ->
	%[<<"chat">>, <<"echo">>].
	[].

%% @doc 返回支持的WebSocket扩展
-spec supportedExtensions() -> [binary()].
supportedExtensions() ->
	[].
