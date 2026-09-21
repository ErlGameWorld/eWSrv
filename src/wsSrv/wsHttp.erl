-module(wsHttp).

-include_lib("kernel/include/logger.hrl").
-include_lib("eNet/include/eNet.hrl").
-include("wsCom.hrl").

-export([
   start_link/1
   , start_link/2
   , sendResponse/5
   , sendFile/5
   %% Exported for looping with a fully-qualified module name
   , toBinStr/1
   , status/1
   , chunkLoop/1
   , spellHeaders/1
   , splitArgs/1
   , closeOrKeepAlive/2
   , maybeSendContinue/2
]).

%% eNet callback
-export([newConn/2]).

-export([
   init_it/2
   , system_code_change/4
   , system_continue/3
   , system_get_state/1
   , system_terminate/4
]).

newConn(Sock, ConnArgs) ->
   case element(1, ConnArgs) of
      undefined ->
         ?MODULE:start_link(ConnArgs);
      WsSupName ->
         supervisor:start_child(WsSupName, [Sock, ConnArgs])
   end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% genActor  start %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec(start_link(atom()) -> {ok, pid()} | ignore | {error, term()}).
start_link(ConnArgs) ->
   proc_lib:start_link(?MODULE, init_it, [self(), ConnArgs], infinity, []).
start_link(Sock, ConnArgs) ->
   proc_lib:start_link(?MODULE, init_it, [self(), {Sock, ConnArgs}], infinity, []).

init_it(Parent, Args) ->
   process_flag(trap_exit, true),
   modInit(Parent, Args).

-spec system_code_change(term(), module(), undefined | term(), term()) -> {ok, term()}.
system_code_change(State, _Module, _OldVsn, _Extra) ->
   {ok, State}.

-spec system_continue(pid(), [], {module(), atom(), pid(), term()}) -> ok.
system_continue(_Parent, _Debug, {Parent, State}) ->
   loop(Parent, State).

-spec system_get_state(term()) -> {ok, term()}.
system_get_state(State) ->
   {ok, State}.

-spec system_terminate(term(), pid(), [], term()) -> none().
system_terminate(Reason, _Parent, _Debug, State) ->
   terminate(Reason, State).

modInit(Parent, Args) ->
   case init(Args) of
      {ok, State} ->
         proc_lib:init_ack(Parent, {ok, self()}),
         loop(Parent, State);
      {stop, Reason} ->
         proc_lib:init_ack(Parent, {error, Reason}),
         exit(Reason)
   end.

-define(STACKTRACE(), element(2, erlang:process_info(self(), current_stacktrace))).
loop(Parent, State) ->
   receive
      {system, From, Request} ->
         sys:handle_system_msg(Request, From, Parent, ?MODULE, [], {Parent, State});
      {'EXIT', Parent, Reason} ->
         terminate(Reason, State);
      Msg ->
         case handleMsg(Msg, State) of
            kpS ->
               loop(Parent, State);
            {ok, NewState} ->
               loop(Parent, NewState);
            {stop, Reason} ->
               terminate(Reason, State);
            {stop, Reason, NewState} ->
               terminate(Reason, NewState)
         end
   after loopTimeout(State) ->
      handleLoopTimeout(State)
   end.

handleLoopTimeout(#wsState{stage = reqLine, buffer = <<>>, requestStartedAt = undefined} = State) ->
   terminate(normal, State);
handleLoopTimeout(#wsState{stage = wsWs} = State) ->
   loop(self(), State);
handleLoopTimeout(#wsState{socket = Socket} = State) ->
   catch sendRescueResponse(Socket, 408, <<"Request Timeout">>),
   terminate(timeout, State).

loopTimeout(#wsState{stage = wsWs}) ->
   infinity;
loopTimeout(#wsState{protocol = http2, keepAliveTimeout = Timeout}) ->
   Timeout;
loopTimeout(#wsState{stage = reqLine, buffer = <<>>, requestStartedAt = undefined,
   keepAliveTimeout = Timeout}) ->
   Timeout;
loopTimeout(#wsState{requestStartedAt = undefined, requestTimeout = Timeout}) ->
   Timeout;
loopTimeout(#wsState{requestStartedAt = Started, requestTimeout = Timeout}) ->
   Now = erlang:monotonic_time(millisecond),
   erlang:max(0, Timeout - (Now - Started)).

matchCallMsg(CurState, From, Request) ->
   #wsState{wsMod = WsMod, webState = WebState} = CurState,
   try WsMod:handleCall(Request, WebState, From) of
      Result ->
         handleCR(CurState, Result, From)
   catch
      throw:Result ->
         handleCR(CurState, Result, From);
      Class:Reason:Strace ->
         From /= false andalso gen_server:reply(From, {error, {inner_error, {Class, Reason, Strace}}}),
         innerError(CurState, {{call, From}, Request}, Class, Reason, Strace),
         kpS
   end.

matchCastMsg(CurState, Cast) ->
   #wsState{wsMod = WsMod, webState = WebState} = CurState,
   try WsMod:handleCast(Cast, WebState) of
      Result ->
         handleCR(CurState, Result, false)
   catch
      throw:Result ->
         handleCR(CurState, Result, false);
      Class:Reason:Strace ->
         innerError(CurState, {cast, Cast}, Class, Reason, Strace),
         kpS
   end.

matchInfoMsg(CurState, Cast) ->
   #wsState{wsMod = WsMod, webState = WebState} = CurState,
   try WsMod:handleInfo(Cast, WebState) of
      Result ->
         handleCR(CurState, Result, false)
   catch
      throw:Result ->
         handleCR(CurState, Result, false);
      Class:Reason:Strace ->
         innerError(CurState, {cast, Cast}, Class, Reason, Strace),
         kpS
   end.

handleCR(CurState, Result, From) ->
   case Result of
      kpS ->
         kpS;
      {reply, Reply} ->
         gen_server:reply(From, Reply),
         kpS;
      {mayReply, Reply} ->
         case From of
            false ->
               kpS;
            _ ->
               gen_server:reply(From, Reply),
               kpS
         end;
      {noreply, NewState} ->
         {ok, CurState#wsState{webState = NewState}};
      {reply, Reply, NewState} ->
         gen_server:reply(From, Reply),
         {ok, CurState#wsState{webState = NewState}};
      {mayReply, Reply, NewState} ->
         case From of
            false ->
               {ok, CurState#wsState{webState = NewState}};
            _ ->
               gen_server:reply(From, Reply),
               {ok, CurState#wsState{webState = NewState}}
         end;
      {stop, Reason, NewState} ->
         {stop, Reason, CurState#wsState{webState = NewState}};
      {stopReply, Reason, Reply, NewState} ->
         gen_server:reply(From, Reply),
         {stop, Reason, CurState#wsState{webState = NewState}};
      _AnyRet ->
         innerError(CurState, {return, _AnyRet}, error, bad_ret, ?STACKTRACE()),
         kpS
   end.

innerError(_CurState, Error, Class, Reason, Strace) ->
   logger:error("wsHttp inner error ~p ~p ~p ~p ~p", [?MODULE, Error, Class, Reason, Strace]),
   ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% genActor  end %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ************************************************  API ***************************************************************
init(Args) ->
   case Args of
      {undefined, WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage, Http2} ->
         {ok, newConnState(WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage, Http2, false, undefined)};
      {_Socket, {_WsSupName, WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage, Http2}} ->
         case maybeInitHandler(WsMod, Args) of
            {ok, WebState} ->
               {ok, newConnState(WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage, Http2, true, WebState)};
            {stop, Reason} ->
               {stop, Reason}
         end;
      %% 兼容旧版eNet传入的4元组连接参数。
      {undefined, WsMod, MaxSize, ChunkedSupp} ->
         {ok, newConnState(WsMod, MaxSize, ChunkedSupp, ?DefMaxRequestLineSize, ?DefMaxHeaderSize, ?DefMaxWsFrameSize, ?DefMaxWsMessageSize, false, false, undefined)};
      {_Socket, {_WsSupName, WsMod, MaxSize, ChunkedSupp}} ->
         case maybeInitHandler(WsMod, Args) of
            {ok, WebState} ->
               {ok, newConnState(WsMod, MaxSize, ChunkedSupp, ?DefMaxRequestLineSize, ?DefMaxHeaderSize, ?DefMaxWsFrameSize, ?DefMaxWsMessageSize, false, true, WebState)};
            {stop, Reason} ->
               {stop, Reason}
         end
   end.

newConnState(WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage, Http2, IsBehavior, WebState) ->
   Protocol = case Http2 of true -> detect; false -> http1 end,
   #wsState{
      wsMod = WsMod,
      maxSize = MaxSize,
      chunkedSupp = ChunkedSupp,
      maxRequestLineSize = MaxReqLine,
      maxHeaderSize = MaxHeader,
      maxWsFrameSize = MaxWsFrame,
      maxWsMessageSize = MaxWsMessage,
      http2Enabled = Http2,
      protocol = Protocol,
      is_behavior = IsBehavior,
      webState = WebState
   }.

maybeInitHandler(WsMod, Args) ->
   case erlang:function_exported(WsMod, init, 1) of
      true -> WsMod:init(Args);
      false -> {ok, undefined}
   end.

handleMsg({tcp, _Socket, Data}, #wsState{protocol = http2, h2State = H2} = State) ->
   handleHttp2Data(Data, H2, State);
handleMsg({tcp, _Socket, Data}, #wsState{protocol = detect, http2Enabled = true} = State) ->
   detectCleartextProtocol(Data, State);
handleMsg({tcp, _Socket, Data}, State0) ->
   State = ensureRequestStarted(State0),
   #wsState{stage = Stage, socket = Socket} = State,
   case wsHttpProtocol:request(Stage, Data, Socket, State) of
      {wsDone, NewState} ->
         Response = doHandle(NewState),
         #wsState{buffer = NBuffer, socket = Socket, temHeader = TemHeader, method = Method, wsReq = WsReq} = NewState,
         Version = WsReq#wsReq.version,
         case doResponse(Response, Socket, TemHeader, Method, Version) of
            keep_alive ->
               case NBuffer of
                  <<>> ->
                     {ok, newWsState(NewState)};
                  _ ->
                     handleMsg({tcp, Socket, NBuffer}, newWsState(NewState))
               end;
            keep_ws ->
               %% Switch to WebSocket stage and notify handler
               %% 添加WebSocket扩展支持（如果模块支持）
               TemWsState = newWsState(NewState),
               NewWsState = TemWsState#wsState{stage = wsWs},
               case NBuffer of
                  <<>> -> {ok, NewWsState};
                  _ ->
                     handleMsg({tcp, Socket, NBuffer}, NewWsState)
               end;
            close ->
               {stop, normal}
         end;
      {ok, _NewState} = LRet ->
         LRet;
      {close, _NewState} ->
         {stop, normal};
      {close, Reason, NewState} ->
         maybeSendWsClose(NewState, Reason),
         {stop, Reason};
      Err ->
         case Err of
            {err_code, Code} ->
               sendRescueResponse(Socket, Code, <<>>),
               {stop, Err};
            _ ->
               ?wsErr("recv the http data error ~p~n", [Err]),
               Stage /= wsWs andalso sendBadRequest(Socket),
               {stop, Err}
         end
   end;
handleMsg({tcp_closed, _Socket}, _State) ->
   {stop, normal};
handleMsg({tcp_error, _Socket, Reason}, _State) ->
   ?wsErr("the http tcp socket error ~p~n", [Reason]),
   {stop, tcp_error};
handleMsg({tcp_passive, Socket}, _State) ->
   wsNet:setopts(Socket, [{active, ?ActionN}]),
   kpS;

handleMsg({ssl, _Socket, Data}, #wsState{protocol = http2, h2State = H2} = State) ->
   handleHttp2Data(Data, H2, State);
handleMsg({ssl, _Socket, Data}, State0) ->
   State = ensureRequestStarted(State0),
   #wsState{stage = Stage, socket = Socket} = State,
   case wsHttpProtocol:request(Stage, Data, Socket, State) of
      {wsDone, NewState} ->
         Response = doHandle(NewState),
         #wsState{buffer = NBuffer, temHeader = TemHeader, method = Method, wsReq = WsReq} = NewState,
         Version = WsReq#wsReq.version,
         case doResponse(Response, Socket, TemHeader, Method, Version) of
            keep_alive ->
               case NBuffer of
                  <<>> ->
                     {ok, newWsState(NewState)};
                  _ ->
                     handleMsg({ssl, Socket, NBuffer}, newWsState(NewState))
               end;
            keep_ws ->
               %% Switch to WebSocket stage and notify handler
               TemWsState = newWsState(NewState),
               NewWsState = TemWsState#wsState{stage = wsWs},
               case NBuffer of
                  <<>> -> {ok, NewWsState};
                  _ ->
                     handleMsg({ssl, Socket, NBuffer}, NewWsState)
               end;
            close ->
               {stop, normal}
         end;
      {ok, _NewState} = LRet ->
         LRet;
      {close, _NewState} ->
         {stop, normal};
      {close, Reason, NewState} ->
         maybeSendWsClose(NewState, Reason),
         {stop, Reason};
      Err ->
         case Err of
            {err_code, Code} ->
               sendRescueResponse(Socket, Code, <<>>),
               {stop, Err};
            _ ->
               ?wsErr("recv the http data error ~p~n", [Err]),
               Stage /= wsWs andalso sendBadRequest(Socket),
               {stop, Err}
         end
   end;
handleMsg({ssl_closed, _Socket}, _State) ->
   {stop, normal};
handleMsg({ssl_passive, Socket}, _State) ->
   wsNet:setopts(Socket, [{active, ?ActionN}]),
   kpS;
handleMsg({ssl_error, _Socket, Reason}, _State) ->
   ?wsErr("the http ssl socket error ~p~n", [Reason]),
   {stop, ssl_error};
handleMsg({?mSockReady, Socket}, State) ->
   inet:setopts(Socket, [{packet, raw}, {active, ?ActionN}]),
   {ok, State#wsState{socket = Socket}};
handleMsg({?mSockReady, Socket, SslOpts, SslHSTet}, State) ->
   case ntSslAcceptor:handshake(Socket, SslOpts, SslHSTet) of
      {ok, SslSock} ->
         ssl:setopts(SslSock, [{packet, raw}, {active, ?ActionN}]),
         sslProtocolState(SslSock, State#wsState{socket = SslSock, isSsl = true});
      _Err ->
         ?wsErr("ssl handshake error ~p~n", [_Err]),
         {stop, handshake_error}
   end;
handleMsg(Msg, #wsState{is_behavior = IsBehaviour} = State) ->
   case IsBehaviour of
      true ->
         case Msg of
            {'$gen_call', From, Request} ->
               matchCallMsg(State, From, Request);
            {'$gen_cast', Cast} ->
               matchCastMsg(State, Cast);
            _ ->
               matchInfoMsg(State, Msg)
         end;
      _ ->
         ?wsErr("~p info receive unexpect msg ~p ~n ", [?MODULE, Msg]),
         kpS
   end.

detectCleartextProtocol(Data, #wsState{buffer = Buffer} = State) ->
   All = <<Buffer/binary, Data/binary>>,
   Preface = <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>,
   CheckLen = erlang:min(byte_size(All), byte_size(Preface)),
   Prefix = binary:part(Preface, 0, CheckLen),
   case binary:part(All, 0, CheckLen) =:= Prefix of
      false ->
         %% 不是HTTP/2 prior-knowledge，完整交回HTTP/1 parser。
         handleMsg({tcp, State#wsState.socket, All},
            State#wsState{protocol = http1, buffer = <<>>});
      true when byte_size(All) < byte_size(Preface) ->
         {ok, State#wsState{buffer = All}};
      true ->
         case startHttp2(State#wsState{buffer = <<>>}, http) of
            {ok, H2State, NState} -> handleHttp2Data(All, H2State, NState);
            {error, Reason} -> {stop, {http2_start, Reason}}
         end
   end.

sslProtocolState(SslSock, #wsState{http2Enabled = true} = State) ->
   case ssl:negotiated_protocol(SslSock) of
      {ok, <<"h2">>} ->
         case startHttp2(State, https) of
            {ok, _H2, NState} -> {ok, NState};
            {error, Reason} -> {stop, {http2_start, Reason}}
         end;
      _ ->
         {ok, State#wsState{protocol = http1}}
   end;
sslProtocolState(_SslSock, State) ->
   {ok, State#wsState{protocol = http1}}.

startHttp2(#wsState{socket = Socket, wsMod = WsMod, maxSize = MaxBody,
   maxHeaderSize = MaxHeader} = State, Scheme) ->
   H20 = wsHttp2:new(Socket, WsMod, Scheme, MaxBody, MaxHeader),
   case wsHttp2:start(H20) of
      {ok, H2} ->
         NState = State#wsState{
            protocol = http2,
            h2State = H2,
            requestStartedAt = undefined,
            buffer = <<>>
         },
         {ok, H2, NState};
      {error, Reason} ->
         {error, Reason}
   end.

handleHttp2Data(Data, H2, State) ->
   case wsHttp2:handleData(Data, H2) of
      {ok, NH2} -> {ok, State#wsState{h2State = NH2}};
      {stop, Reason, NH2} -> {stop, Reason, State#wsState{h2State = NH2}}
   end.

maybeSendWsClose(#wsState{stage = wsWs}, normal) ->
   %% 正常Close handshake已在wsWebSocket中回显Close帧。
   ok;
maybeSendWsClose(#wsState{stage = wsWs, socket = Socket}, Reason) ->
   Code =
      case Reason of
         message_too_big -> 1009;
         invalid_utf8 -> 1007;
         _ -> 1002
      end,
   catch wsWebSocket:sendFrame(Socket, ?WsOpClose, <<Code:16>>),
   ok;
maybeSendWsClose(_State, _Reason) ->
   ok.

terminate(Reason, #wsState{socket = Socket, wsMod = WsMod, webState = WebState, is_behavior = IsBehavior} = _State) ->
   case IsBehavior andalso erlang:function_exported(WsMod, terminate, 2) of
      true ->
         try WsMod:terminate(Reason, WebState) catch _:_ -> ok end;
      false ->
         ok
   end,
   try wsNet:close(Socket)
   catch _:_ -> ok
   end,
   exit(Reason).

ensureRequestStarted(#wsState{stage = wsWs} = State) ->
   State;
ensureRequestStarted(#wsState{requestStartedAt = undefined} = State) ->
   State#wsState{requestStartedAt = erlang:monotonic_time(millisecond)};
ensureRequestStarted(State) ->
   State.

newWsState(WsState) ->
   WsState#wsState{
      stage = reqLine
      , buffer = <<>>
      , wsReq = undefined
      , headerCnt = 0
      , headerBytes = 0
      , hostHeaderSeen = false
      , temHeader = []
      , contentLength = undefined
      , bodyAcc = []
      , bodySize = 0
      , chunkState = size
      , temChunked = <<>>
      , requestStartedAt = undefined
   }.

%% @doc Execute the user callback, translating failure into a proper response.
doHandle(State) ->
   #wsState{wsMod = WsMod, method = Method, path = Path, wsReq = WsReq} = State,
   try WsMod:handle(Method, Path, WsReq) of
      %% {ok,...{file,...}}
      {ok, Headers, {file, Filename}} ->
         {file, 200, Headers, Filename, []};
      {ok, Headers, {file, Filename, Range}} ->
         {file, 200, Headers, Filename, Range};
      %% ok simple
      {ok, Headers, Body} -> {response, 200, Headers, Body};
      {ok, Body} -> {response, 200, [], Body};
      %% Chunk
      {chunk, Headers} -> {chunk, Headers, <<"">>};
      {chunk, Headers, Initial} -> {chunk, Headers, Initial};
      %% WebSocket升级
      {wsUpgrade, Headers} -> wsWebSocket:handleUpgrade(WsMod, Headers);
      %% File
      {HttpCode, Headers, {file, Filename}} ->
         {file, HttpCode, Headers, Filename, {0, 0}};
      {HttpCode, Headers, {file, Filename, Range}} ->
         {file, HttpCode, Headers, Filename, Range};
      %% Simple
      {HttpCode, Headers, Body} -> {response, HttpCode, Headers, Body};
      {HttpCode, Body} -> {response, HttpCode, [], Body};
      %% Unexpected
      Unexpected ->
         ?wsErr("handle return error WsReq:~p Ret:~p~n", [WsReq, Unexpected]),
         {response, 500, [], <<"Internal server error">>}
   catch
      throw:{ResponseCode, Headers, Body} when is_integer(ResponseCode) ->
         {response, ResponseCode, Headers, Body};
      throw:Exc:Stacktrace ->
         ?wsErr("handle catch throw WsReq:~p R:~p S:~p~n", [WsReq, Exc, Stacktrace]),
         {response, 500, [], <<"Internal server error">>};
      error:Error:Stacktrace ->
         ?wsErr("handle catch error WsReq:~p R:~p S:~p~n", [WsReq, Error, Stacktrace]),
         {response, 500, [], <<"Internal server error">>};
      exit:Exit:Stacktrace ->
         ?wsErr("handle catch exit WsReq:~p R:~p S:~p~n", [WsReq, Exit, Stacktrace]),
         {response, 500, [], <<"Internal server error">>}
   end.

%% Inject compression for normal responses
doResponse({response, Code, UserHeaders0, Body}, Socket, ReqHeaders, Method, Version) ->
   {SBody, UserHeaders1} = tryCompressResponse(Body, UserHeaders0, ReqHeaders, Code, Method),
   UserHeaders = lists:keydelete(<<"Transfer-Encoding">>, 1,
      lists:keydelete(<<"Content-Length">>, 1, UserHeaders1)),
   NHeaders = normalizeContentLength(Code, Method, iolist_size(SBody), UserHeaders),
   Policy = connectionPolicy(UserHeaders, ReqHeaders, Version),
   Headers = addConnectionHeader(NHeaders, Policy, Version),
   sendResponse(Socket, Method, Code, Headers, SBody),
   Policy;
doResponse({chunk, UserHeaders0, Initial}, Socket, ReqHeaders, Method, Version) ->
   UserHeaders = lists:keydelete(<<"Content-Length">>, 1, UserHeaders0),
   Policy = connectionPolicy(UserHeaders, ReqHeaders, Version),
   ResponseHeaders = addConnectionHeader(
      [transferEncoding(UserHeaders) | UserHeaders], Policy, Version),
   sendResponse(Socket, Method, 200, ResponseHeaders, <<>>),
   case Method of
      'HEAD' ->
         ok;
      _ ->
         Initial =:= <<"">> orelse sendChunk(Socket, Initial),
         case startChunkLoop(Socket) of
            {error, client_closed} -> client;
            ok -> server
         end
   end,
   Policy;
%% WebSocket升级响应
doResponse({wsWebSocket, UserHeaders}, Socket, _ReqHeaders, _Method, _Version) ->
   sendResponse(Socket, 'GET', 101, UserHeaders, <<>>),
   keep_ws;
doResponse({file, ResponseCode, UserHeaders0, Filename, Range}, Socket, ReqHeaders, Method, Version) ->
   Policy = connectionPolicy(UserHeaders0, ReqHeaders, Version),
   UserHeaders = lists:keydelete(<<"Content-Length">>, 1, UserHeaders0),
   ResponseHeaders = addConnectionHeader(UserHeaders, Policy, Version),
   case wsUtil:fileSize(Filename) of
      {error, _FileError} ->
         sendSrvError(Socket),
         {stop, file_error};
      Size ->
         Ret =
            case wsUtil:normalizeRange(Range, Size) of
               undefined ->
                  FileHeaders = [{<<"Content-Length">>, Size} | ResponseHeaders],
                  case Method of
                     'HEAD' -> sendResponse(Socket, Method, ResponseCode, FileHeaders, <<>>);
                     _ -> sendFile(Socket, ResponseCode, FileHeaders, Filename, {0, 0})
                  end;
               {Offset, Length} ->
                  ERange = wsUtil:encodeRange({Offset, Length}, Size),
                  FileHeaders = [
                     {<<"Content-Length">>, Length},
                     {<<"Content-Range">>, ERange}
                     | ResponseHeaders
                  ],
                  case Method of
                     'HEAD' -> sendResponse(Socket, Method, 206, FileHeaders, <<>>);
                     _ -> sendFile(Socket, 206, FileHeaders, Filename, {Offset, Length})
                  end;
               invalid_range ->
                  ERange = wsUtil:encodeRange(invalid_range, Size),
                  sendResponse(Socket, Method, 416,
                     [{<<"Content-Length">>, 0}, {<<"Content-Range">>, ERange} | ResponseHeaders], <<>>),
                  ok
            end,
         case Ret of
            ok -> Policy;
            _Err -> {stop, Ret}
         end
   end.

normalizeContentLength(Code, _Method, _BodySize, Headers) when Code >= 100, Code < 200 ->
   Headers;
normalizeContentLength(204, _Method, _BodySize, Headers) ->
   Headers;
normalizeContentLength(304, _Method, _BodySize, Headers) ->
   Headers;
normalizeContentLength(205, _Method, _BodySize, Headers) ->
   [{<<"Content-Length">>, 0} | Headers];
normalizeContentLength(_Code, _Method, BodySize, Headers) ->
   [{<<"Content-Length">>, BodySize} | Headers].

%% @doc Generate a HTTP response and send it to the client.
sendResponse(Socket, Method, Code, Headers, UserBody) ->
   Body =
      case Method of
         'HEAD' ->
            <<>>;
         _ ->
            case Code of
               304 ->
                  <<>>;
               204 ->
                  <<>>;
               _ ->
                  UserBody
            end
      end,

   Response = httpResponse(Code, Headers, Body),
   case wsNet:send(Socket, Response) of
      ok ->
         ok;
      _Err ->
         ?wsErr("send_response error ~p~n", [_Err])
   end.

%% helpers for compression
tryCompressResponse(Body, UserHeaders, ReqHeaders, Code, Method) ->
   BodySize = iolist_size(Body),
   Skip = (Method =:= 'HEAD') orelse (Code =:= 204) orelse (Code =:= 304) orelse BodySize < 1024,
   case Skip of
      true ->
         {Body, UserHeaders};
      false ->
         case lists:keyfind(<<"Content-Encoding">>, 1, UserHeaders) of
            false ->
               case chooseContentEncoding(ReqHeaders) of
                  none ->
                     {Body, UserHeaders};
                  gzip ->
                     CBody = zlib:gzip(iolist_to_binary(Body)),
                     {CBody, addVary([{<<"Content-Encoding">>, <<"gzip">>} | UserHeaders])};
                  deflate ->
                     CBody = zlib:compress(iolist_to_binary(Body)),
                     {CBody, addVary([{<<"Content-Encoding">>, <<"deflate">>} | UserHeaders])}
               end;
            _ ->
               {Body, UserHeaders}
         end
   end.

chooseContentEncoding(ReqHeaders) ->
   case lists:keyfind('Accept-Encoding', 1, ReqHeaders) of
      false ->
         none;
      {_, Value} ->
         Encodings = parseAcceptEncodings(iolist_to_binary(Value)),
         GzipQ = encodingQ(<<"gzip">>, Encodings),
         DeflateQ = encodingQ(<<"deflate">>, Encodings),
         case {GzipQ, DeflateQ} of
            {G, D} when G > 0, G >= D -> gzip;
            {_G, D} when D > 0 -> deflate;
            _ -> none
         end
   end.

parseAcceptEncodings(Value) ->
   [
      begin
         Parts = [string:trim(P) || P <- binary:split(string:lowercase(Token), <<";">>, [global])],
         case Parts of
            [Encoding] -> {Encoding, 1000};
            [Encoding | Params] -> {Encoding, parseEncodingQ(Params)}
         end
      end
      || Token <- binary:split(Value, <<",">>, [global])
   ].

parseEncodingQ(Params) ->
   case [V || P <- Params,
              [K, V] <- [binary:split(P, <<"=">>)],
              string:trim(K) =:= <<"q">>] of
      [Q | _] -> qValue(string:trim(Q));
      [] -> 1000
   end.

qValue(<<"0">>) -> 0;
qValue(<<"1">>) -> 1000;
qValue(<<"0.", Digits/binary>>) -> fractionQ(Digits);
qValue(<<"1.", Digits/binary>>) ->
   case allZero(Digits) of true -> 1000; false -> 0 end;
qValue(_) -> 0.

fractionQ(Digits0) ->
   Digits = binary:part(<<Digits0/binary, "000">>, 0, 3),
   try binary_to_integer(Digits) catch _:_ -> 0 end.

allZero(<<>>) -> true;
allZero(<<$0, Rest/binary>>) -> allZero(Rest);
allZero(_) -> false.

encodingQ(Name, Encodings) ->
   case lists:keyfind(Name, 1, Encodings) of
      {_, Q} -> Q;
      false ->
         case lists:keyfind(<<"*">>, 1, Encodings) of
            {_, Q} -> Q;
            false -> 0
         end
   end.

addVary(Hs) ->
   case lists:keyfind(<<"Vary">>, 1, Hs) of
      false ->
         [{<<"Vary">>, <<"Accept-Encoding">>} | Hs];
      {_, Value} ->
         Tokens = [string:trim(T) || T <- binary:split(iolist_to_binary(Value), <<",">>, [global])],
         case lists:member(<<"Accept-Encoding">>, Tokens) of
            true -> Hs;
            false -> lists:keyreplace(<<"Vary">>, 1, Hs,
               {<<"Vary">>, [Value, <<", Accept-Encoding">>]})
         end
   end.

%% @doc Send a HTTP response to the client where the body is the
%% contents of the given file. Assumes correctly set response code
%% and headers.
-spec sendFile(Socket, Code, Headers, Filename, Range) -> ok | {error, term()} when
   Socket :: wsSocket(),
   Code :: wsHttpCode(),
   Headers :: wsHeaders(),
   Filename :: file:filename(),
   Range :: wsUtil:range().
sendFile(Socket, Code, Headers, Filename, Range) ->
   ResponseHeaders = httpResponse(Code, Headers, <<>>),
   case file:open(Filename, [read, raw, binary]) of
      {ok, Fd} -> doSendFile(Fd, Range, Socket, ResponseHeaders);
      {error, _FileError} = Err ->
         sendSrvError(Socket),
         Err
   end.

doSendFile(Fd, {Offset, Length}, Socket, Headers) ->
   try wsNet:send(Socket, Headers) of
      ok ->
         case wsNet:sendfile(Fd, Socket, Offset, Length, []) of
            {ok, _BytesSent} -> ok;
            {error, Closed} = LErr when Closed =:= closed orelse Closed =:= enotconn ->
               ?wsErr("send file error"),
               LErr
         end;
      {error, Closed} = LErr when Closed =:= closed orelse Closed =:= enotconn ->
         ?wsErr("send file error"),
         LErr
   after
      file:close(Fd)
   end.

%% @doc To send a response, we must first have received everything the
%% client is sending. If this is not the case, {@link send_bad_request/1}
%% might reset the client connection.
sendBadRequest(Socket) ->
   sendRescueResponse(Socket, 400, <<"Bad Request">>).

sendSrvError(Socket) ->
   sendRescueResponse(Socket, 500, <<"Server Error">>).

sendRescueResponse(Socket, Code, Body) ->
   Response = httpResponse(Code, Body),
   wsNet:send(Socket, Response).

%% CHUNKED-TRANSFER
%% @doc The chunk loop is an intermediary between the socket and the
%% user. We forward anything the user sends until the user sends an
%% empty response, which signals that the connection should be
%% closed. When the client closes the socket, the loop exits.
startChunkLoop(Socket) ->
   %% Set the socket to active so we receive the tcp_closed message
   %% if the client closes the connection
   wsNet:setopts(Socket, [{active, ?ActionN}]),
   ?MODULE:chunkLoop(Socket).

chunkLoop(Socket) ->
   receive
      {tcp_closed, Socket} ->
         {error, client_closed};
      {ssl_closed, Socket} ->
         {error, client_closed};
      {tcp_error, Socket, _Reason} ->
         {error, client_closed};
      {ssl_error, Socket, _Reason} ->
         {error, client_closed};
      {tcp_passive, Socket} ->
         wsNet:setopts(Socket, [{active, ?ActionN}]),
         ?MODULE:chunkLoop(Socket);
      {ssl_passive, Socket} ->
         wsNet:setopts(Socket, [{active, ?ActionN}]),
         ?MODULE:chunkLoop(Socket);
      {chunk, close} ->
         case wsNet:send(Socket, <<"0\r\n\r\n">>) of
            ok ->
               ok;
            {error, Closed} when Closed =:= closed orelse Closed =:= enotconn ->
               {error, client_closed}
         end;
      {chunk, close, From} ->
         case wsNet:send(Socket, <<"0\r\n\r\n">>) of
            ok ->
               From ! {self(), ok},
               ok;
            {error, Closed} when Closed =:= closed orelse Closed =:= enotconn ->
               From ! {self(), {error, closed}},
               ok
         end;
      {chunk, Data} ->
         sendChunk(Socket, Data),
         ?MODULE:chunkLoop(Socket);
      {chunk, Data, From} ->
         case sendChunk(Socket, Data) of
            ok ->
               From ! {self(), ok};
            {error, Closed} when Closed =:= closed orelse Closed =:= enotconn ->
               From ! {self(), {error, closed}}
         end,
         ?MODULE:chunkLoop(Socket)
   after 10000 ->
      ?MODULE:chunkLoop(Socket)
   end.

sendChunk(Socket, Data) ->
   case iolist_size(Data) of
      0 -> ok;
      Size ->
         Response = [integer_to_binary(Size, 16), <<"\r\n">>, Data, <<"\r\n">>],
         wsNet:send(Socket, Response)
   end.

maybeSendContinue(Socket, Headers) ->
   %% Expect字段名由decode_packet规范化为atom，值大小写不敏感。
   case wsUtil:getHeader('Expect', Headers, undefined) of
      undefined ->
         ok;
      Value ->
         case wsUtil:toLowerStr(iolist_to_binary(Value)) of
            <<"100-continue">> ->
               wsNet:send(Socket, httpResponse(100));
            _ ->
               ok
         end
   end.

httpResponse(Code) ->
   httpResponse(Code, <<>>).

httpResponse(Code, Body) ->
   httpResponse(Code, [{<<"Content-Length">>, size(Body)}], Body).

httpResponse(Code, Headers, Body) ->
   [<<"HTTP/1.1 ">>, status(Code), <<"\r\n">>, spellHeaders(Headers), <<"\r\n">>, Body].

spellHeaders(Headers) ->
   [[Key, <<": ">>, toBinStr(Value), <<"\r\n">>] || {Key, Value} <- Headers, Key =/= <<>>].

-spec splitArgs(binary()) -> list({binary(), binary() | true}).
splitArgs(<<>>) -> [];
splitArgs(Qs) ->
   Tokens = binary:split(Qs, <<"&">>, [global, trim]),
   [case binary:split(Token, <<"=">>) of [Token] -> {Token, true}; [Name, Value] ->
      {Name, Value} end || Token <- Tokens].

toBinStr(V) when is_integer(V) -> integer_to_binary(V);
toBinStr(V) when is_binary(V) -> V;
toBinStr(V) when is_list(V) -> list_to_binary(V);
toBinStr(V) when is_atom(V) -> atom_to_binary(V).

closeOrKeepAlive(UserHeaders, ReqHeader) ->
   connectionPolicy(UserHeaders, ReqHeader, {1, 1}).

connectionPolicy(UserHeaders, ReqHeaders, Version) ->
   RespClose = headerHasToken(<<"Connection">>, UserHeaders, <<"close">>),
   ReqClose = headerHasToken('Connection', ReqHeaders, <<"close">>),
   ReqKeep = headerHasToken('Connection', ReqHeaders, <<"keep-alive">>),
   case RespClose orelse ReqClose of
      true ->
         close;
      false when Version =:= {1, 0} ->
         case ReqKeep of true -> keep_alive; false -> close end;
      false ->
         keep_alive
   end.

addConnectionHeader(Headers0, Policy, Version) ->
   Headers = lists:keydelete(<<"Connection">>, 1, Headers0),
   case {Policy, Version} of
      {close, _} -> [{<<"Connection">>, <<"close">>} | Headers];
      {keep_alive, {1, 0}} -> [{<<"Connection">>, <<"Keep-Alive">>} | Headers];
      {keep_alive, _} -> Headers
   end.

headerHasToken(Name, Headers, Wanted) ->
   case lists:keyfind(Name, 1, Headers) of
      false -> false;
      {_, Value} ->
         Lower = wsUtil:toLowerStr(iolist_to_binary(Value)),
         Tokens = [string:trim(T) || T <- binary:split(Lower, <<",">>, [global])],
         lists:member(Wanted, Tokens)
   end.

transferEncoding(Headers) ->
   case lists:keyfind(<<"Transfer-Encoding">>, 1, Headers) of
      false ->
         {<<"Transfer-Encoding">>, <<"chunked">>};
      _ ->
         []
   end.

%% HTTP STATUS CODES
status(100) -> <<"100 Continue">>;
status(101) -> <<"101 Switching Protocols">>;
status(102) -> <<"102 Processing">>;
status(200) -> <<"200 OK">>;
status(201) -> <<"201 Created">>;
status(202) -> <<"202 Accepted">>;
status(203) -> <<"203 Non-Authoritative Information">>;
status(204) -> <<"204 No Content">>;
status(205) -> <<"205 Reset Content">>;
status(206) -> <<"206 Partial Content">>;
status(207) -> <<"207 Multi-Status">>;
status(226) -> <<"226 IM Used">>;
status(300) -> <<"300 Multiple Choices">>;
status(301) -> <<"301 Moved Permanently">>;
status(302) -> <<"302 Found">>;
status(303) -> <<"303 See Other">>;
status(304) -> <<"304 Not Modified">>;
status(305) -> <<"305 Use Proxy">>;
status(306) -> <<"306 Switch Proxy">>;
status(307) -> <<"307 Temporary Redirect">>;
status(308) -> <<"308 Permanent Redirect">>;
status(400) -> <<"400 Bad Request">>;
status(401) -> <<"401 Unauthorized">>;
status(402) -> <<"402 Payment Required">>;
status(403) -> <<"403 Forbidden">>;
status(404) -> <<"404 Not Found">>;
status(405) -> <<"405 Method Not Allowed">>;
status(406) -> <<"406 Not Acceptable">>;
status(407) -> <<"407 Proxy Authentication Required">>;
status(408) -> <<"408 Request Timeout">>;
status(409) -> <<"409 Conflict">>;
status(410) -> <<"410 Gone">>;
status(411) -> <<"411 Length Required">>;
status(412) -> <<"412 Precondition Failed">>;
status(413) -> <<"413 Request Entity Too Large">>;
status(414) -> <<"414 Request-URI Too Long">>;
status(415) -> <<"415 Unsupported Media Type">>;
status(416) -> <<"416 Requested Range Not Satisfiable">>;
status(417) -> <<"417 Expectation Failed">>;
status(418) -> <<"418 I'm a teapot">>;
status(422) -> <<"422 Unprocessable Entity">>;
status(423) -> <<"423 Locked">>;
status(424) -> <<"424 Failed Dependency">>;
status(425) -> <<"425 Unordered Collection">>;
status(426) -> <<"426 Upgrade Required">>;
status(428) -> <<"428 Precondition Required">>;
status(429) -> <<"429 Too Many Requests">>;
status(431) -> <<"431 Request Header Fields Too Large">>;
status(500) -> <<"500 Internal Server Error">>;
status(501) -> <<"501 Not Implemented">>;
status(502) -> <<"502 Bad Gateway">>;
status(503) -> <<"503 Service Unavailable">>;
status(504) -> <<"504 Gateway Timeout">>;
status(505) -> <<"505 HTTP Version Not Supported">>;
status(506) -> <<"506 Variant Also Negotiates">>;
status(507) -> <<"507 Insufficient Storage">>;
status(510) -> <<"510 Not Extended">>;
status(511) -> <<"511 Network Authentication Required">>;
status(I) when is_integer(I), I >= 100, I < 1000 -> <<(integer_to_binary(I))/binary, "Status">>;
status(B) when is_binary(B) -> B.
