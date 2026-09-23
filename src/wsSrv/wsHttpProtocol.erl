-module(wsHttpProtocol).

-include("wsCom.hrl").

-compile(inline).
-compile({inline_size, 128}).

-export([request/4]).

-spec request(Stage :: stage(), Data :: binary(), wsSocket(), State :: #wsState{}) ->
   {ok, NewState :: #wsState{}} |
   {wsDone, NewState :: #wsState{}} |
   {close, term(), NewState :: #wsState{}} |
   {error, term()} |
   {err_code, integer()}.
request(reqLine, Data0, Socket, State) ->
   Data = mergeBuffer(Data0, State),
   Max = State#wsState.maxRequestLineSize,
   case erlang:decode_packet(http_bin, Data, []) of
      {more, _} when byte_size(Data) > Max ->
         {err_code, 414};
      {more, _} ->
         {ok, State#wsState{buffer = Data}};
      {ok, {http_request, Method0, RawPath, Version}, Rest} ->
         Method = normalizeMethod(Method0),
         ReqLineSize = byte_size(Data) - byte_size(Rest),
         case ReqLineSize > Max of
            true ->
               {err_code, 414};
            false ->
               case parseRequestTarget(Method, RawPath) of
                  {ok, Scheme0, Host, Port, Path, URLArgs} ->
                     Scheme = requestScheme(Scheme0, State),
                     WsReq = #wsReq{
                        method = Method, path = Path, version = Version,
                        scheme = Scheme, host = Host, port = Port,
                        socket = Socket, args = URLArgs
                     },
                     NState = State#wsState{
                        stage = wsHeader, buffer = <<>>, method = Method,
                        path = Path, wsReq = WsReq
                     },
                     case Rest of
                        <<>> -> {ok, NState};
                        _ -> request(wsHeader, Rest, Socket, NState)
                     end;
                  Error ->
                     Error
               end
         end;
      {ok, {http_error, ErrStr}, _} ->
         {error, ErrStr};
      {ok, {http_response, _, _, _}, _} ->
         {error, http_response};
      {error, _Reason} = Ret ->
         Ret
   end;

request(wsHeader, Data0, Socket, State) ->
   Data = mergeBuffer(Data0, State),
   parseHeaders(Data, Socket, State#wsState{buffer = <<>>});

request(wsBody, Data0, _Socket, #wsState{contentLength = chunked} = State) ->
   parseChunked(Data0, State);

request(wsBody, Data, _Socket, #wsState{contentLength = CLen} = State)
   when is_integer(CLen), CLen >= 0 ->
   parseFixedBody(Data, CLen, State);

request(wsWs, Data, _Socket, State) ->
   case wsWebSocket:feed(Data, State) of
      {ok, [], NState} ->
         {ok, NState};
      {ok, Frames, NState} ->
         wsWebSocket:processFrames(Frames, NState);
      {close, Reason} ->
         {close, Reason, State};
      {error, Reason} ->
         {close, Reason, State}
   end.

mergeBuffer(Data, #wsState{buffer = <<>>}) ->
   Data;
mergeBuffer(Data, #wsState{buffer = Buffer}) ->
   <<Buffer/binary, Data/binary>>.

parseHeaders(Data, Socket, State) ->
   MaxHeaderSize = State#wsState.maxHeaderSize,
   HeaderBytes0 = State#wsState.headerBytes,
   case erlang:decode_packet(httph_bin, Data, []) of
      {more, _} ->
         case HeaderBytes0 + byte_size(Data) > MaxHeaderSize of
            true -> {err_code, 431};
            false -> {ok, State#wsState{buffer = Data}}
         end;
      {ok, {http_header, _, Key, _, Value}, Rest} ->
         LineBytes = byte_size(Data) - byte_size(Rest),
         HeaderBytes = HeaderBytes0 + LineBytes,
         case HeaderBytes > MaxHeaderSize of
            true ->
               {err_code, 431};
            false ->
               parseOneHeader(Key, Value, Rest, Socket, State#wsState{headerBytes = HeaderBytes})
         end;
      {ok, http_eoh, Rest} ->
         HeaderBytes = HeaderBytes0 + (byte_size(Data) - byte_size(Rest)),
         case HeaderBytes > MaxHeaderSize of
            true ->
               {err_code, 431};
            false ->
               finishHeaders(Rest, Socket, State#wsState{headerBytes = HeaderBytes})
         end;
      {ok, {http_error, ErrStr}, _Rest} ->
         {error, ErrStr};
      {error, _Reason} = Ret ->
         Ret
   end.

parseOneHeader(Key, Value, Rest, Socket, #wsState{headerCnt = HeaderCnt, temHeader = Headers} = State) ->
   NewHeaderCnt = HeaderCnt + 1,
   case NewHeaderCnt > 100 of
      true ->
         {err_code, 431};
      false ->
         NState = State#wsState{headerCnt = NewHeaderCnt, temHeader = [{Key, Value} | Headers]},
         case Key of
            'Content-Length' ->
               parseContentLength(Value, Rest, Socket, NState);
            'Transfer-Encoding' ->
               parseTransferEncoding(Value, Rest, Socket, NState);
            'Host' ->
               parseHost(Value, Rest, Socket, NState);
            'Connection' ->
               parseConnection(Value, Rest, Socket, NState);
            _ ->
               parseHeaders(Rest, Socket, NState)
         end
   end.

parseContentLength(Value, Rest, Socket, #wsState{contentLength = Current, maxSize = MaxSize} = State) ->
   case parseNonNegativeInteger(Value) of
      {ok, Length} ->
         case {Current, exceedsMax(Length, MaxSize)} of
            {chunked, _} ->
               {error, content_length_transfer_encoding_conflict};
            {_, true} ->
               {err_code, 413};
            {undefined, false} ->
               parseHeaders(Rest, Socket, State#wsState{contentLength = Length});
            {Length, false} ->
               %% RFC allows identical duplicated Content-Length values.
               parseHeaders(Rest, Socket, State);
            {_Other, false} ->
               {error, conflicting_content_length}
         end;
      error ->
         {error, invalid_content_length}
   end.

parseTransferEncoding(Value, Rest, Socket, #wsState{contentLength = Current, chunkedSupp = ChunkedSupp} = State) ->
   case Current of
      N when is_integer(N) ->
         {error, content_length_transfer_encoding_conflict};
      chunked ->
         {error, duplicate_transfer_encoding};
      _ ->
         case validChunkedEncoding(Value) of
            false ->
               {error, unsupported_transfer_encoding};
            true when ChunkedSupp =:= false ->
               {error, not_support_chunked};
            true ->
               parseHeaders(Rest, Socket, State#wsState{contentLength = chunked, chunkState = size})
         end
   end.

parseHost(_Value, _Rest, _Socket, #wsState{hostHeaderSeen = true}) ->
   {error, duplicate_host};
parseHost(Value, Rest, Socket, #wsState{wsReq = WsReq} = State) ->
   case parseHostHeader(Value, defaultPort(WsReq#wsReq.scheme)) of
      {Host, Port} ->
         NewWsReq =
            case WsReq#wsReq.host of
               undefined -> WsReq#wsReq{host = Host, port = Port};
               _ -> WsReq
            end,
         parseHeaders(Rest, Socket, State#wsState{hostHeaderSeen = true, wsReq = NewWsReq});
      error ->
         {error, invalid_host}
   end.

parseConnection(Value, Rest, Socket, State) ->
   %% 常见值走无分配快路径；复杂 token 列表只解析一次。
   case Value of
      <<"close">> ->
         parseHeaders(Rest, Socket, State#wsState{reqConnClose = true});
      <<"keep-alive">> ->
         parseHeaders(Rest, Socket, State#wsState{reqConnKeepAlive = true});
      _ ->
         {HasClose, HasKeepAlive} = connectionTokens(Value),
         parseHeaders(Rest, Socket, State#wsState{
            reqConnClose = State#wsState.reqConnClose orelse HasClose,
            reqConnKeepAlive = State#wsState.reqConnKeepAlive orelse HasKeepAlive
         })
   end.

connectionTokens(Value) ->
   connectionTokens(binary:split(iolist_to_binary(Value), <<",">>, [global]), false, false).

connectionTokens([], HasClose, HasKeepAlive) ->
   {HasClose, HasKeepAlive};
connectionTokens([Token0 | Rest], HasClose, HasKeepAlive) ->
   Token = string:trim(Token0),
   IsClose = wsUtil:headerNameEq(Token, <<"close">>),
   IsKeepAlive = wsUtil:headerNameEq(Token, <<"keep-alive">>),
   connectionTokens(Rest, HasClose orelse IsClose, HasKeepAlive orelse IsKeepAlive).

finishHeaders(Rest, Socket,
   #wsState{temHeader = TemHeader0, contentLength = CLen, wsReq = WsReq0, hostHeaderSeen = HostSeen} = State) ->
   Version = WsReq0#wsReq.version,
   case Version =:= {1, 1} andalso not HostSeen of
      true ->
         {error, missing_host};
      false ->
         TemHeader = lists:reverse(TemHeader0),
         WsReq = WsReq0#wsReq{headers = TemHeader},
         %% 只有确定会读取Body时才发送100 Continue。
         case CLen of
            0 ->
               {wsDone, State#wsState{buffer = Rest, wsReq = WsReq, temHeader = TemHeader}};
            undefined ->
               {wsDone, State#wsState{buffer = Rest, wsReq = WsReq, temHeader = TemHeader}};
            _ ->
               case wsHttp:maybeSendContinue(Socket, TemHeader) of
                  {error, unsupported_expectation} ->
                     {err_code, 417};
                  {error, Reason} ->
                     {error, {continue_send_failed, Reason}};
                  _ ->
                     NState = State#wsState{stage = wsBody, buffer = <<>>, wsReq = WsReq,
                        temHeader = TemHeader, bodyAcc = [], bodySize = 0},
                     case Rest of
                        <<>> -> {ok, NState};
                        _ -> request(wsBody, Rest, Socket, NState)
                     end
               end
         end
   end.

parseFixedBody(Data, CLen, #wsState{bodyAcc = Acc, bodySize = Size0, wsReq = WsReq} = State) ->
   Need = CLen - Size0,
   DataSize = byte_size(Data),
   case DataSize of
      N when N < Need ->
         {ok, State#wsState{buffer = <<>>, bodyAcc = [Data | Acc], bodySize = Size0 + N}};
      N when N =:= Need ->
         Body = finishBody([Data | Acc]),
         {wsDone, State#wsState{buffer = <<>>, bodyAcc = [], bodySize = CLen, wsReq = WsReq#wsReq{body = Body}}};
      _ ->
         <<Part:Need/binary, Rest/binary>> = Data,
         Body = finishBody([Part | Acc]),
         {wsDone, State#wsState{buffer = Rest, bodyAcc = [], bodySize = CLen, wsReq = WsReq#wsReq{body = Body}}}
   end.

parseChunked(Data0, State0) ->
   Data = mergeBuffer(Data0, State0),
   parseChunkedState(Data, State0#wsState{buffer = <<>>}).

parseChunkedState(Data, #wsState{chunkState = size} = State) ->
   case binary:match(Data, <<"\r\n">>) of
      nomatch ->
         %% chunk-size line is attacker controlled; keep it tightly bounded.
         case byte_size(Data) > 1024 of
            true -> {error, chunk_size_line_too_long};
            false -> {ok, State#wsState{buffer = Data}}
         end;
      {Pos, 2} ->
         <<SizeLine:Pos/binary, "\r\n", Rest/binary>> = Data,
         case parseChunkSize(SizeLine) of
            error ->
               {error, invalid_chunk_size};
            {ok, 0} ->
               parseChunkedState(Rest, State#wsState{chunkState = trailers});
            {ok, ChunkSize} ->
               case wouldExceed(State#wsState.bodySize, ChunkSize, State#wsState.maxSize) of
                  true -> {err_code, 413};
                  false ->
                     parseChunkedState(Rest, State#wsState{chunkState = {data, ChunkSize}})
               end
         end
   end;

parseChunkedState(Data, #wsState{chunkState = {data, Remaining}, bodyAcc = Acc, bodySize = Size0} = State) ->
   DataSize = byte_size(Data),
   case DataSize >= Remaining of
      false ->
         {ok, State#wsState{
            buffer = <<>>,
            bodyAcc = [Data | Acc],
            bodySize = Size0 + DataSize,
            chunkState = {data, Remaining - DataSize}
         }};
      true ->
         <<Part:Remaining/binary, Rest/binary>> = Data,
         parseChunkedState(Rest, State#wsState{bodyAcc = [Part | Acc], bodySize = Size0 + Remaining, chunkState = crlf})
   end;

parseChunkedState(Data, #wsState{chunkState = crlf} = State) ->
   case Data of
      <<"\r\n", Rest/binary>> ->
         parseChunkedState(Rest, State#wsState{chunkState = size});
      <<>> ->
         {ok, State};
      <<"\r">> ->
         {ok, State#wsState{buffer = <<"\r">>}};
      _ ->
         {error, invalid_chunk_terminator}
   end;

parseChunkedState(Data, #wsState{chunkState = trailers, maxHeaderSize = MaxHeaderSize, wsReq = WsReq, bodyAcc = Acc} = State) ->
   case Data of
      <<"\r\n", Rest/binary>> ->
         Body = finishBody(Acc),
         {wsDone, State#wsState{buffer = Rest, bodyAcc = [], chunkState = size, wsReq = WsReq#wsReq{body = Body}}};
      _ ->
         case binary:match(Data, <<"\r\n\r\n">>) of
            {Pos, 4} when Pos =< MaxHeaderSize ->
               <<Trailers:Pos/binary, "\r\n\r\n", Rest/binary>> = Data,
               case parseChunkTrailers(<<Trailers/binary, "\r\n\r\n">>, 0, []) of
                  {ok, TrailerHeaders} ->
                     Body = finishBody(Acc),
                     {wsDone, State#wsState{
                        buffer = Rest, bodyAcc = [], chunkState = size,
                        wsReq = WsReq#wsReq{
                           body = Body,
                           trailers = TrailerHeaders
                        }
                     }};
                  {error, _} = Error ->
                     Error
               end;
            {Pos, 4} when Pos > MaxHeaderSize ->
               {err_code, 431};
            nomatch when byte_size(Data) > MaxHeaderSize ->
               {err_code, 431};
            nomatch ->
               {ok, State#wsState{buffer = Data}}
         end
   end.

parseChunkTrailers(_Data, Count, _Acc) when Count > 100 ->
   {error, too_many_trailers};
parseChunkTrailers(Data, Count, Acc) ->
   case erlang:decode_packet(httph_bin, Data, []) of
      {ok, {http_header, _, Key, _, Value}, Rest} ->
         case forbiddenTrailer(Key) of
            true -> {error, forbidden_trailer};
            false -> parseChunkTrailers(Rest, Count + 1, [{Key, Value} | Acc])
         end;
      {ok, http_eoh, <<>>} ->
         {ok, lists:reverse(Acc)};
      {ok, http_eoh, _Rest} ->
         {error, malformed_trailers};
      {ok, {http_error, Reason}, _} ->
         {error, {invalid_trailer, Reason}};
      {more, _} ->
         {error, incomplete_trailers};
      {error, Reason} ->
         {error, {invalid_trailer, Reason}}
   end.

forbiddenTrailer('Content-Length') -> true;
forbiddenTrailer('Transfer-Encoding') -> true;
forbiddenTrailer('Host') -> true;
forbiddenTrailer('Connection') -> true;
forbiddenTrailer('Upgrade') -> true;
forbiddenTrailer('Keep-Alive') -> true;
forbiddenTrailer('Proxy-Connection') -> true;
forbiddenTrailer(Key) when is_binary(Key) ->
   wsUtil:headerNameEq(Key, <<"Trailer">>) orelse
   wsUtil:headerNameEq(Key, <<"TE">>);
forbiddenTrailer(_) -> false.

finishBody([]) ->
   <<>>;
finishBody([One]) when is_binary(One) ->
   One;
finishBody(Acc) ->
   iolist_to_binary(lists:reverse(Acc)).

parseNonNegativeInteger(Value) when is_binary(Value) ->
   Bin = string:trim(Value),
   %% Content-Length = 1*DIGIT。binary_to_integer/1 也接受 +1/-1，
   %% 不能直接拿它当语法校验，否则不同 HTTP 实现可能产生 framing 分歧。
   case Bin =/= <<>> andalso byte_size(Bin) =< 20 andalso allDecimalDigits(Bin) of
      true ->
         try {ok, binary_to_integer(Bin)} catch _:_ -> error end;
      false ->
         error
   end.

allDecimalDigits(<<>>) ->
   true;
allDecimalDigits(<<C, Rest/binary>>) when C >= $0, C =< $9 ->
   allDecimalDigits(Rest);
allDecimalDigits(_) ->
   false.

exceedsMax(_Length, infinity) ->
   false;
exceedsMax(Length, Max) ->
   Length > Max.

wouldExceed(_Current, _Add, infinity) ->
   false;
wouldExceed(Current, Add, Max) ->
   Current + Add > Max.

validChunkedEncoding(Value) ->
   Tokens = binary:split(iolist_to_binary(Value), <<",">>, [global]),
   %% eWSrv currently implements only the chunked transfer coding.
   case Tokens of
      [T] -> wsUtil:headerNameEq(string:trim(T), <<"chunked">>);
      _ -> false
   end.

parseChunkSize(Line0) ->
   Line = string:trim(Line0),
   [Hex | _] = binary:split(Line, <<";">>, [global]),
   case Hex of
      <<>> -> error;
      _ ->
         try
            N = binary_to_integer(Hex, 16),
            case N >= 0 of true -> {ok, N}; false -> error end
         catch
            _:_ -> error
         end
   end.

requestScheme(undefined, #wsState{isSsl = true}) -> <<"https">>;
requestScheme(undefined, _State) -> <<"http">>;
requestScheme(Scheme, _State) -> Scheme.

defaultPort(<<"https">>) -> 443;
defaultPort(https) -> 443;
defaultPort(_) -> 80.

%% 解析Host头，支持 hostname、hostname:port、[IPv6]、[IPv6]:port。
parseHostHeader(<<"[", Rest/binary>>, DefaultPort) ->
   case binary:match(Rest, <<"]">>) of
      nomatch -> error;
      {Pos, 1} ->
         <<Host:Pos/binary, "]", Tail/binary>> = Rest,
         case Tail of
            <<>> -> {Host, DefaultPort};
            <<":", PortBin/binary>> ->
               case parsePort(PortBin) of
                  {ok, Port} -> {Host, Port};
                  error -> error
               end;
            _ -> error
         end
   end;
parseHostHeader(HostHeader, DefaultPort) when is_binary(HostHeader), HostHeader =/= <<>> ->
   case binary:match(HostHeader, <<":">>) of
      nomatch ->
         {HostHeader, DefaultPort};
      {Pos, 1} when Pos > 0 ->
         <<Host:Pos/binary, ":", PortBin/binary>> = HostHeader,
         case binary:match(PortBin, <<":">>) of
            nomatch ->
               case parsePort(PortBin) of
                  {ok, Port} -> {Host, Port};
                  error -> error
               end;
            _ ->
               %% Unbracketed IPv6 is not a valid Host authority.
               error
         end;
      _ ->
         error
   end;
parseHostHeader(_, _DefaultPort) ->
   error.

parsePort(Bin) ->
   try
      Port = binary_to_integer(Bin),
      case Port >= 1 andalso Port =< 65535 of
         true -> {ok, Port};
         false -> error
      end
   catch
      _:_ -> error
   end.

normalizeMethod(<<"CONNECT">>) -> 'CONNECT';
normalizeMethod(<<"PATCH">>) -> 'PATCH';
normalizeMethod(Method) -> Method.

parseRequestTarget('OPTIONS', '*') ->
   {ok, undefined, undefined, undefined, <<"*">>, []};
parseRequestTarget(_Method, '*') ->
   {error, invalid_request_target};
parseRequestTarget('CONNECT', {scheme, Host, PortBin})
   when is_binary(Host), is_binary(PortBin), Host =/= <<>> ->
   case parsePort(PortBin) of
      {ok, Port} ->
         {ok, undefined, Host, Port, <<Host/binary, ":", PortBin/binary>>, []};
      error ->
         {error, invalid_connect_target}
   end;
parseRequestTarget('CONNECT', Target) when is_binary(Target) ->
   case parseHostHeader(Target, undefined) of
      {Host, Port} when is_integer(Port) ->
         {ok, undefined, Host, Port, Target, []};
      _ ->
         {error, invalid_connect_target}
   end;
parseRequestTarget(_Method, RawPath) ->
   parsePath(RawPath).

parsePath({abs_path, FullPath}) when is_binary(FullPath) ->
   %% origin-form = absolute-path [ "?" query ]。HTTP request-target 不含 fragment，
   %% 因此无需通用 uri_string:parse/1；直接拆 query 可覆盖绝大多数业务路径。
   case binary:match(FullPath, <<"#">>) of
      {_, _} ->
         {error, invalid_uri};
      nomatch ->
         case binary:split(FullPath, <<"?">>) of
            [Path0] ->
               Path = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
               {ok, undefined, undefined, undefined, Path, []};
            [Path0, Query] ->
               Path = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
               try
                  {ok, undefined, undefined, undefined, Path, uri_string:dissect_query(Query)}
               catch
                  _:_ -> {error, invalid_uri}
               end
         end
   end;
parsePath({absoluteURI, Scheme, Host, Port0, Path}) ->
   case parsePath({abs_path, Path}) of
      {ok, _Scheme, _Host, _Port, RetPath, RetQuery} ->
         Port = case Port0 of undefined -> defaultPort(Scheme); _ -> Port0 end,
         {ok, Scheme, Host, Port, RetPath, RetQuery};
      Error ->
         Error
   end;
parsePath(_) ->
   {error, unsupported_uri}.

