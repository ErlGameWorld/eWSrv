-module(eWSrv).

-include("wsCom.hrl").

-export([
	start/0
	, stop/0
	, openSrv/2
	, openSrv/3
	, closeSrv/1
	, wSrvName/1
	, main/1
]).

-export([
	method/1
	, path/1
	, version/1
	, scheme/1
	, host/1
	, port/1
	, socket/1
	, args/1
	, mapargs/1
	, headers/1
	, trailers/1
	, body/1
]).

%% 监听器名。
%% 子类：
%%   atom() —— 约定形如 '$WSrv<Port>'（wSrvName/1 生成）；
%%             openSrv/3 也允许调用方自定义名字。
%% 该名字同时是 eNet 侧 supervisor 的 child id，同名重复 open 会失败。
-type srvName() :: atom().

%% 监听端口。
%%   0        —— 由内核分配一个空闲端口，真实端口需从 eNet 侧查询（测试常用）；
%%   1..65535 —— 显式端口，被占用时 openSrv 返回 {error, ...}。

%% openSrv/2,3 的监听选项列表，每一项都是 eWSrv.hrl 的 wsOpt/0。按用途分三类：
%%   1) 限额类（抵御慢速攻击 / 超大报文）
%%        {maxSize, infinity | pos_integer()}         请求体上限，默认 8MB
%%        {maxRequestLineSize, pos_integer()}         请求行上限，默认 8KB
%%        {maxHeaderSize, pos_integer()}              请求头总大小上限，默认 64KB
%%        {maxWsFrameSize, pos_integer()}             WebSocket 单帧上限，默认 1MB
%%        {maxWsMessageSize, pos_integer()}           WebSocket 单消息上限，默认 8MB
%%   2) 协议行为类
%%        {wsMod, module()}                           请求回调模块，默认 wsTPHer
%%        {chunkedSupp, boolean()}                    是否接受 chunked 请求体，默认 false
%%        {http2, boolean()}                          是否启用 HTTP/2（TLS ALPN + 明文 prior knowledge），默认 true
%%        {http2MaxConcurrentStreams, pos_integer()}  本端允许的并发 stream 数，默认 100
%%        {http2ReceiveWindow, 65535..2147483647}     H2 接收窗口，默认 65535
%%        {requestTimeout, pos_integer()}             单个请求接收超时(ms)，默认 30000
%%        {keepAliveTimeout, pos_integer()}           空闲 Keep-Alive 超时(ms)，默认 60000
%%   3) 承载 / 进程类（透传给 eNet 的 listenOpt/0）
%%        {wsSupName, pid() | term()}                 连接进程的挂载 supervisor，默认 undefined
%%        {tcpOpts, [gen_tcp:listen_option()]}        TCP 选项，与 ?DefWsOpts 合并后生效
%%        {sslOpts, [ssl:tls_option()]}               有值则走 TLS 监听，否则明文 TCP
%%        {conMod, atom()}                            连接回调模块；openSrv 强制填 wsHttp
%%        {conArgs, term()}                           连接参数；openSrv 内部生成，外部传入会被覆盖
%% 重叠处理：conMod / conArgs / tcpOpts 由 openSrv 用 lists:keystore 覆盖，其余取列表首项。
-type srvOpts() :: [wsOpt()].


%% 启动 eWSrv 及其依赖（eNet）。
%% 成功返回已启动的应用列表（按依赖顺序，eNet 在前），失败返回原因。
-spec start() -> {ok, Started :: [atom()]} | {error, Reason :: term()}.
start() ->
	application:ensure_all_started(eWSrv).

%% 停止 eWSrv 应用本身；已打开的监听器随之关闭，eNet 保持运行。
%% 应用未启动时返回 {error, {not_started, eWSrv}}。
-spec stop() -> ok | {error, Reason :: {not_started, eWSrv} | term()}.
stop() ->
	application:stop(eWSrv).

%% 由端口推导监听器名，规则：'$WSrv' ++ integer_to_binary(Port)。
%% 例：wSrvName(8080) -> '$WSrv8080'。
%% 注意：binary_to_atom/1 会创建新 atom，端口值应来自可信配置，勿直接透传用户输入。
-spec wSrvName(Port :: inet:port_number()) -> SrvName :: srvName().
wSrvName(Port) ->
	binary_to_atom(<<"$WSrv", (integer_to_binary(Port))/binary>>).

%% 在 Port 上打开 HTTP/WebSocket 监听器，监听器名自动取 wSrvName(Port)。
%% 明文 -> eNet:openTcp/3，TLS（给了 sslOpts）-> eNet:openSsl/3，
%%   http2 = true 且走 TLS 时，会自动补 ALPN、收窄 TLS 版本、关闭重协商。
-spec openSrv(Port :: inet:port_number(), WsOpts :: srvOpts()) -> Result :: {ok, ListenPid :: pid()} | {error, Reason :: term()}.
openSrv(Port, WsOpts) ->
	T1WsOpts = lists:keystore(conMod, 1, WsOpts, {conMod, wsHttp}),
	WsMod = ?wsGLV(wsMod, WsOpts, wsTPHer),
	MaxSize = ?wsGLV(maxSize, WsOpts, ?DefMaxBodySize),
	MaxRequestLineSize = ?wsGLV(maxRequestLineSize, WsOpts, ?DefMaxRequestLineSize),
	MaxHeaderSize = ?wsGLV(maxHeaderSize, WsOpts, ?DefMaxHeaderSize),
	MaxWsFrameSize = ?wsGLV(maxWsFrameSize, WsOpts, ?DefMaxWsFrameSize),
	MaxWsMessageSize = ?wsGLV(maxWsMessageSize, WsOpts, ?DefMaxWsMessageSize),
	ChunkedSupp = ?wsGLV(chunkedSupp, WsOpts, false),
	Http2 = ?wsGLV(http2, WsOpts, true),
	Http2MaxConcurrent = h2PositiveOpt(http2MaxConcurrentStreams, ?wsGLV(http2MaxConcurrentStreams, WsOpts, ?DefHttp2MaxConcurrentStreams)),
	Http2ReceiveWindow = h2ReceiveWindowOpt(?wsGLV(http2ReceiveWindow, WsOpts, ?DefHttp2ReceiveWindow)),
	RequestTimeout = ?wsGLV(requestTimeout, WsOpts, ?DefRequestTimeout),
	KeepAliveTimeout = ?wsGLV(keepAliveTimeout, WsOpts, ?DefKeepAliveTimeout),
	WsSupName = ?wsGLV(wsSupName, WsOpts, undefined),
	ConArgs = {WsSupName, WsMod, MaxSize, ChunkedSupp, MaxRequestLineSize, MaxHeaderSize, MaxWsFrameSize, MaxWsMessageSize, Http2, RequestTimeout, KeepAliveTimeout, Http2MaxConcurrent, Http2ReceiveWindow},
	T2WsOpts = lists:keystore(conArgs, 1, T1WsOpts, {conArgs, ConArgs}),
	TcpOpts = ?wsGLV(tcpOpts, T2WsOpts, []),
	NewTcpOpts = wsUtil:mergeOpts(?DefWsOpts, TcpOpts),
	LWsOpts = lists:keystore(tcpOpts, 1, T2WsOpts, {tcpOpts, NewTcpOpts}),

	WSrvName = wSrvName(Port),
	case ?wsGLV(sslOpts, WsOpts, false) of
		false ->
			eNet:openTcp(WSrvName, Port, LWsOpts);
		SslOpts ->
			HSslOpts = http2SslOpts(Http2, SslOpts),
			SrvOpts = lists:keystore(sslOpts, 1, LWsOpts, {sslOpts, HSslOpts}),
			eNet:openSsl(WSrvName, Port, SrvOpts)
	end.

%% 同上，但监听器名由调用方显式指定（便于自定义可读名，或在测试里用唯一名字反复 open/close）
-spec openSrv(SrvName :: atom(), Port :: inet:port_number(), WsOpts :: srvOpts()) -> Result :: {ok, ListenPid :: pid()} | {error, Reason :: term()}.
openSrv(WSrvName, Port, WsOpts) ->
	T1WsOpts = lists:keystore(conMod, 1, WsOpts, {conMod, wsHttp}),
	WsMod = ?wsGLV(wsMod, WsOpts, wsTPHer),
	MaxSize = ?wsGLV(maxSize, WsOpts, ?DefMaxBodySize),
	MaxRequestLineSize = ?wsGLV(maxRequestLineSize, WsOpts, ?DefMaxRequestLineSize),
	MaxHeaderSize = ?wsGLV(maxHeaderSize, WsOpts, ?DefMaxHeaderSize),
	MaxWsFrameSize = ?wsGLV(maxWsFrameSize, WsOpts, ?DefMaxWsFrameSize),
	MaxWsMessageSize = ?wsGLV(maxWsMessageSize, WsOpts, ?DefMaxWsMessageSize),
	ChunkedSupp = ?wsGLV(chunkedSupp, WsOpts, false),
	Http2 = ?wsGLV(http2, WsOpts, true),
	Http2MaxConcurrent = h2PositiveOpt(http2MaxConcurrentStreams, ?wsGLV(http2MaxConcurrentStreams, WsOpts, ?DefHttp2MaxConcurrentStreams)),
	Http2ReceiveWindow = h2ReceiveWindowOpt(?wsGLV(http2ReceiveWindow, WsOpts, ?DefHttp2ReceiveWindow)),
	RequestTimeout = ?wsGLV(requestTimeout, WsOpts, ?DefRequestTimeout),
	KeepAliveTimeout = ?wsGLV(keepAliveTimeout, WsOpts, ?DefKeepAliveTimeout),
	WsSupName = ?wsGLV(wsSupName, WsOpts, undefined),
	ConArgs = {WsSupName, WsMod, MaxSize, ChunkedSupp, MaxRequestLineSize, MaxHeaderSize, MaxWsFrameSize, MaxWsMessageSize, Http2, RequestTimeout, KeepAliveTimeout, Http2MaxConcurrent, Http2ReceiveWindow},
	T2WsOpts = lists:keystore(conArgs, 1, T1WsOpts, {conArgs, ConArgs}),
	TcpOpts = ?wsGLV(tcpOpts, T2WsOpts, []),
	NewTcpOpts = wsUtil:mergeOpts(?DefWsOpts, TcpOpts),
	LWsOpts = lists:keystore(tcpOpts, 1, T2WsOpts, {tcpOpts, NewTcpOpts}),

	case ?wsGLV(sslOpts, WsOpts, false) of
		false ->
			eNet:openTcp(WSrvName, Port, LWsOpts);
		SslOpts ->
			HSslOpts = http2SslOpts(Http2, SslOpts),
			SrvOpts = lists:keystore(sslOpts, 1, LWsOpts, {sslOpts, HSslOpts}),
			eNet:openSsl(WSrvName, Port, SrvOpts)
	end.

%% 关闭监听器。关闭后该端口不再接受新连接，已建立的连接不受影响。
%% 子类（参数形态）：srvName() 直接用；Port 内部经 wSrvName/1 转成名字。
%% 子类（返回值）：
%%   {ok, ShutdownPid} —— 监听器已终止并删除；
%%   ignore            —— 该名字下没有监听器（重复关闭是安全的）；
%%   {error, Reason}   —— 终止/删除失败。
-spec closeSrv(SrvNameOrPort :: srvName() | inet:port_number()) -> Result :: {ok, ShutdownPid :: pid()} | ignore | {error, Reason :: term()}.
closeSrv(WSrvNameOrPort) ->
	WSrvName = ?CASE(is_integer(WSrvNameOrPort), wSrvName(WSrvNameOrPort), WSrvNameOrPort),
	eNet:close(WSrvName).

%% ==================== escript entry ====================
%% Usage: _build/default/bin/eWSrv --port 8888
%% Args 只接受恰好一个十进制端口字符串（配合 rebar.config 的 escript 配置）。
%% 成功：打印监听地址后进入永久阻塞（进程不退出）；
%% 失败：打印原因并以退出码 1 结束。两种情况都不会正常返回。
-spec main(Args :: [string()]) -> no_return().
main([PortStr]) ->
	Port = list_to_integer(PortStr),
	{ok, _} = start(),
	case openSrv(Port, []) of
		{ok, _} ->
			io:format("eWSrv listening on http://0.0.0.0:~p/~n", [Port]),
			io:format("Open http://127.0.0.1:~p/demo for the demo page.\n", [Port]),
			receive after infinity -> ok end;
		Error ->
			io:format("Failed to open server: ~p~n", [Error]),
			erlang:halt(1)
	end.

%% ==================== 内部辅助 ====================
%% 按 http2 开关补全 TLS 选项：仅 http2 = true 时补 ALPN、收窄 TLS 版本、关闭重协商。 子类（SslOpts）：false（调用方没给 TLS 选项，原样返回）| [ssl:tls_option()]。
-spec http2SslOpts(Http2 :: boolean(), SslOpts :: false | [ssl:tls_option()]) -> Result :: false | [ssl:tls_option()].
http2SslOpts(false, SslOpts) ->
	SslOpts;
http2SslOpts(true, SslOpts) when is_list(SslOpts) ->
	WithAlpn = lists:keystore(alpn_preferred_protocols, 1, SslOpts, {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}),
	WithTls = enforceHttp2Tls(WithAlpn),
	WithReneg = lists:keystore(client_renegotiation, 1, WithTls, {client_renegotiation, false}),
	lists:keystore(secure_renegotiate, 1, WithReneg, {secure_renegotiate, true}).

%% HTTP/2 over TLS 只允许 TLS 1.2 和 1.3。调用方若指定了更低版本，丢掉。 子类（versions 项）：[]（显式给空 -> 回落到 1.2/1.3）| ['tlsv1.2' | 'tlsv1.3' | 其他版本 atom]。
-spec enforceHttp2Tls(SslOpts :: [ssl:tls_option()]) -> Result :: [ssl:tls_option()].
enforceHttp2Tls(SslOpts) ->
	case lists:keyfind(versions, 1, SslOpts) of
		false ->
			lists:keystore(versions, 1, SslOpts, {versions, ['tlsv1.2', 'tlsv1.3']});
		{versions, Vs} ->
			Allowed = [V || V <- Vs, V =:= 'tlsv1.2' orelse V =:= 'tlsv1.3'],
			Safe = case Allowed of [] -> ['tlsv1.2', 'tlsv1.3']; _ -> Allowed end,
			lists:keystore(versions, 1, SslOpts, {versions, Safe})
	end.

%% 校验 HTTP/2 正整数型选项（并发 stream 数等）。 子类：合法 -> 1..16#7fffffff；非法（0 / 负数 / 超 2^31-1 / 非整数）-> erlang:error/1。
-spec h2PositiveOpt(Name :: atom(), Value :: term()) -> Value2 :: 1..16#7fffffff.
h2PositiveOpt(_Name, Value) when is_integer(Value), Value > 0, Value =< 16#7fffffff ->
	Value;
h2PositiveOpt(Name, Value) ->
	erlang:error({bad_option, Name, Value}).

%% 校验 HTTP/2 接收窗口下限不能小于 65535（= H2 默认窗口，RFC 9113 允许调大不可调小）。 子类：合法 -> 65535..2^31-1；非法 -> erlang:error/1。
-spec h2ReceiveWindowOpt(Value :: term()) -> Value2 :: 65535..16#7fffffff.
h2ReceiveWindowOpt(Value) when is_integer(Value), Value >= 65535, Value =< 16#7fffffff ->
	Value;
h2ReceiveWindowOpt(Value) ->
	erlang:error({bad_option, http2ReceiveWindow, Value}).

%% ==================== 请求访问器 ====================
%% 以下 12 个函数都只做「记录字段 -> 值」的取出，登录 #wsReq{}（见 eWSrv.hrl），回调 handler 里用它们避免直接依赖记录字段名。
method(#wsReq{method = Method}) -> Method.
path(#wsReq{path = Path}) -> Path.
version(#wsReq{version = Version}) -> Version.
scheme(#wsReq{scheme = Scheme}) -> Scheme.
host(#wsReq{host = Host}) -> Host.
port(#wsReq{port = Port}) -> Port.
socket(#wsReq{socket = Socket}) -> Socket.
args(#wsReq{args = Args}) -> Args.
mapargs(#wsReq{args = Args}) -> maps:from_list(Args).
headers(#wsReq{headers = Headers}) -> Headers.
trailers(#wsReq{trailers = Trailers}) -> Trailers.
body(#wsReq{body = Body}) -> Body.
