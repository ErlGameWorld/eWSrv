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
   , tryCompressResponse/5
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
         %% 无外部 supervisor 时也必须走 start_link/2。旧路径丢掉 Sock，
         %% 同时跳过 WsMod:init/1 并关闭 behavior 消息分发，导致默认配置
         %% 与配置 wsSupName 时的回调语义不一致。
         ?MODULE:start_link(Sock, ConnArgs);
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
         try handleMsg(Msg, State) of
            kpS ->
               loop(Parent, State);
            {ok, NewState} ->
               loop(Parent, NewState);
            {stop, Reason} ->
               terminate(Reason, State);
            {stop, Reason, NewState} ->
               terminate(Reason, NewState)
         catch
            Class:CrashReason:Stack ->
               ?wsErr("wsHttp handleMsg crash ~p:~p ~p", [Class, CrashReason, Stack]),
               terminate({handler_crash, Class, CrashReason}, State)
         end
   after loopTimeout(State) ->
      case handleLoopTimeout(State) of
         {ok, NewState} ->
            loop(Parent, NewState);
         {stop, Reason} ->
            terminate(Reason, State);
         {stop, Reason, NewState} ->
            terminate(Reason, NewState)
      end
   end.

handleLoopTimeout(#wsState{protocol = http2, h2State = H2} = State) when is_map(H2) ->
   NH2 = wsHttp2:idleClose(H2),
   _ = erlang:send_after(50, self(), h2_drain_close),
   {ok, State#wsState{h2State = NH2}};
handleLoopTimeout(#wsState{stage = reqLine, buffer = <<>>, requestStartedAt = undefined}) ->
   {stop, normal};
handleLoopTimeout(#wsState{stage = wsWs} = State) ->
   {ok, State};
handleLoopTimeout(#wsState{socket = Socket}) ->
   try sendRescueResponse(Socket, 408, <<"Request Timeout">>)
   catch _:_ -> ok
   end,
   {stop, timeout}.

loopTimeout(#wsState{stage = wsWs}) ->
   infinity;
loopTimeout(#wsState{protocol = http2, h2State = H2, keepAliveTimeout = Timeout}) ->
   case is_map(H2) andalso wsHttp2:hasOpenStreams(H2) of
      true -> infinity;
      false -> Timeout
   end;
loopTimeout(#wsState{stage = reqLine, buffer = <<>>, requestStartedAt = undefined, keepAliveTimeout = Timeout}) ->
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
      {undefined, WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage,
         Http2, RequestTimeout, KeepAliveTimeout} ->
         {ok, newConnState(WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage,
            Http2, RequestTimeout, KeepAliveTimeout, false, undefined)};
      {_Socket, {_WsSupName, WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage,
         Http2, RequestTimeout, KeepAliveTimeout}} ->
         case maybeInitHandler(WsMod, Args) of
            {ok, WebState} ->
               {ok, newConnState(WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage,
                  Http2, RequestTimeout, KeepAliveTimeout, true, WebState)};
            {stop, Reason} ->
               {stop, Reason}
         end;
      %% 兼容前一版feature分支的9元组连接参数。
      {undefined, WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage, Http2} ->
         {ok, newConnState(WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage,
            Http2, ?DefRequestTimeout, ?DefKeepAliveTimeout, false, undefined)};
      {_Socket, {_WsSupName, WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage, Http2}} ->
         case maybeInitHandler(WsMod, Args) of
            {ok, WebState} ->
               {ok, newConnState(WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage,
                  Http2, ?DefRequestTimeout, ?DefKeepAliveTimeout, true, WebState)};
            {stop, Reason} ->
               {stop, Reason}
         end;
      %% 兼容旧版eNet传入的4元组连接参数。
      {undefined, WsMod, MaxSize, ChunkedSupp} ->
         {ok, newConnState(WsMod, MaxSize, ChunkedSupp, ?DefMaxRequestLineSize, ?DefMaxHeaderSize, ?DefMaxWsFrameSize,
            ?DefMaxWsMessageSize, false, ?DefRequestTimeout, ?DefKeepAliveTimeout, false, undefined)};
      {_Socket, {_WsSupName, WsMod, MaxSize, ChunkedSupp}} ->
         case maybeInitHandler(WsMod, Args) of
            {ok, WebState} ->
               {ok, newConnState(WsMod, MaxSize, ChunkedSupp, ?DefMaxRequestLineSize, ?DefMaxHeaderSize,
                  ?DefMaxWsFrameSize, ?DefMaxWsMessageSize, false, ?DefRequestTimeout, ?DefKeepAliveTimeout,
                  true, WebState)};
            {stop, Reason} ->
               {stop, Reason}
         end
   end.

newConnState(WsMod, MaxSize, ChunkedSupp, MaxReqLine, MaxHeader, MaxWsFrame, MaxWsMessage,
   Http2, RequestTimeout, KeepAliveTimeout, IsBehavior, WebState) ->
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
      requestTimeout = RequestTimeout,
      keepAliveTimeout = KeepAliveTimeout,
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
   #wsState{stage = Stage, socket = Socket} = State0,
   case wsHttpProtocol:request(Stage, Data, Socket, State0) of
      {wsDone, NewState} ->
         Response = doHandle(NewState),
         #wsState{
            buffer = NBuffer, socket = Socket, temHeader = TemHeader, method = Method, wsReq = WsReq,
            reqConnClose = ReqClose, reqConnKeepAlive = ReqKeepAlive
         } = NewState,
         Version = WsReq#wsReq.version,
         case doResponse(Response, Socket, TemHeader, Method, Version, {ReqClose, ReqKeepAlive}) of
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
               {stop, normal};
            {stop, Reason} ->
               {stop, Reason};
            {stop, Reason, StopState} ->
               {stop, Reason, StopState}
         end;
      {ok, NewState} ->
         %% 完整单包请求无需读取 monotonic clock；只有需要等待后续数据时
         %% 才启动 requestTimeout 计时，避免给 /hello 这类热路径增加固定成本。
         {ok, markRequestStarted(State0, NewState)};
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
handleMsg(h2_drain_close, #wsState{protocol = http2} = _State) ->
   {stop, normal};
handleMsg({h2_settings_ack_timeout, Token}, #wsState{protocol = http2, h2State = H2} = State) ->
   case wsHttp2:handleSettingsTimeout(Token, H2) of
      {ok, NH2} -> {ok, State#wsState{h2State = NH2}};
      {stop, Reason, NH2} -> {stop, Reason, State#wsState{h2State = NH2}}
   end;
handleMsg({h2_request_timeout, StreamId, Token}, #wsState{protocol = http2, h2State = H2} = State) ->
   case wsHttp2:handleRequestTimeout(StreamId, Token, H2) of
      {ok, NH2} -> {ok, State#wsState{h2State = NH2}};
      {stop, Reason, NH2} -> {stop, Reason, State#wsState{h2State = NH2}}
   end;
handleMsg({h2_stream_start, StreamId, WorkerPid, Token, Req, Headers, Initial},
   #wsState{protocol = http2, h2State = H2} = State) ->
   case wsHttp2:handleStreamStart(StreamId, WorkerPid, Token, Req, Headers, Initial, H2) of
      {ok, NH2} -> {ok, State#wsState{h2State = NH2}};
      {stop, Reason, NH2} -> {stop, Reason, State#wsState{h2State = NH2}}
   end;
handleMsg({h2_stream_chunk, StreamId, WorkerPid, Token, Data, From},
   #wsState{protocol = http2, h2State = H2} = State) ->
   case wsHttp2:handleStreamChunk(StreamId, WorkerPid, Token, Data, From, H2) of
      {ok, NH2} -> {ok, State#wsState{h2State = NH2}};
      {stop, Reason, NH2} -> {stop, Reason, State#wsState{h2State = NH2}}
   end;
handleMsg({h2_stream_close, StreamId, WorkerPid, From}, #wsState{protocol = http2, h2State = H2} = State) ->
   case wsHttp2:handleStreamClose(StreamId, WorkerPid, From, H2) of
      {ok, NH2} -> {ok, State#wsState{h2State = NH2}};
      {stop, Reason, NH2} -> {stop, Reason, State#wsState{h2State = NH2}}
   end;
handleMsg({h2_response, StreamId, WorkerPid, Req, Response}, #wsState{protocol = http2, h2State = H2} = State) ->
   case wsHttp2:handleResponse(StreamId, WorkerPid, Req, Response, H2) of
      {ok, NH2} -> {ok, State#wsState{h2State = NH2}};
      {stop, Reason, NH2} -> {stop, Reason, State#wsState{h2State = NH2}}
   end;
handleMsg({'DOWN', MonitorRef, process, _Pid, Reason}, #wsState{protocol = http2, h2State = H2} = State) ->
   case wsHttp2:handleWorkerDown(MonitorRef, Reason, H2) of
      {ok, NH2} -> {ok, State#wsState{h2State = NH2}};
      {stop, StopReason, NH2} -> {stop, StopReason, State#wsState{h2State = NH2}}
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
   #wsState{stage = Stage, socket = Socket} = State0,
   case wsHttpProtocol:request(Stage, Data, Socket, State0) of
      {wsDone, NewState} ->
         Response = doHandle(NewState),
         #wsState{
            buffer = NBuffer, temHeader = TemHeader, method = Method, wsReq = WsReq,
            reqConnClose = ReqClose, reqConnKeepAlive = ReqKeepAlive
         } = NewState,
         Version = WsReq#wsReq.version,
         case doResponse(Response, Socket, TemHeader, Method, Version, {ReqClose, ReqKeepAlive}) of
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
               {stop, normal};
            {stop, Reason} ->
               {stop, Reason};
            {stop, Reason, StopState} ->
               {stop, Reason, StopState}
         end;
      {ok, NewState} ->
         %% 完整单包请求无需读取 monotonic clock；只有需要等待后续数据时
         %% 才启动 requestTimeout 计时，避免给 /hello 这类热路径增加固定成本。
         {ok, markRequestStarted(State0, NewState)};
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
         handleMsg({tcp, State#wsState.socket, All}, State#wsState{protocol = http1, buffer = <<>>});
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

startHttp2(#wsState{socket = Socket, wsMod = WsMod, maxSize = MaxBody, maxHeaderSize = MaxHeader} = State, Scheme) ->
   H20 = wsHttp2:new(Socket, WsMod, Scheme, MaxBody, MaxHeader, State#wsState.requestTimeout),
   case wsHttp2:start(H20) of
      {ok, H2} ->
         NState = State#wsState{protocol = http2, h2State = H2, requestStartedAt = undefined, buffer = <<>>},
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
   try wsWebSocket:sendFrame(Socket, ?WsOpClose, <<Code:16>>)
   catch _:_ -> ok
   end,
   ok;
maybeSendWsClose(_State, _Reason) ->
   ok.

terminate(Reason, #wsState{socket = Socket, wsMod = WsMod, webState = WebState,
   is_behavior = IsBehavior, protocol = Protocol, h2State = H2State} = _State) ->
   case {Protocol, H2State} of
      {http2, H2} when is_map(H2) ->
         try wsHttp2:terminate(H2)
         catch _:_ -> ok
         end;
      _ ->
         ok
   end,
   case IsBehavior andalso erlang:function_exported(WsMod, terminate, 2) of
      true ->
         try WsMod:terminate(Reason, WebState) catch _:_ -> ok end;
      false ->
         ok
   end,
   try wsNet:close(Socket)
   catch _:_ -> ok
   end,
   %% 走到这里都是协议处理完后的主动关闭。proc_lib 只把
   %% normal / shutdown / {shutdown, _} 视为正常结束，其它原因会打 CRASH REPORT。
   exit(shutdown_reason(Reason)).

shutdown_reason(normal) -> normal;
shutdown_reason(shutdown) -> shutdown;
shutdown_reason({shutdown, _} = Reason) -> Reason;
shutdown_reason(Reason) -> {shutdown, Reason}.

markRequestStarted(#wsState{stage = wsWs}, State) ->
   State;
markRequestStarted(#wsState{requestStartedAt = undefined}, State) ->
   State#wsState{requestStartedAt = erlang:monotonic_time(millisecond)};
markRequestStarted(_OldState, State) ->
   State.

newWsState(WsState) ->
   WsState#wsState{
      stage = reqLine
      , buffer = <<>>
      , wsParse = undefined
      , wsReq = undefined
      , headerCnt = 0
      , headerBytes = 0
      , hostHeaderSeen = false
      , reqConnClose = false
      , reqConnKeepAlive = false
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
      {wsUpgrade, Headers} -> wsWebSocket:handleUpgrade(WsMod, WsReq, Headers);
      %% File。Range=[] 表示整文件；勿传 {0,0}，那会被当成显式空范围。
      {HttpCode, Headers, {file, Filename}}
         when is_integer(HttpCode), HttpCode >= 200, HttpCode =< 999 ->
         {file, HttpCode, Headers, Filename, []};
      {HttpCode, Headers, {file, Filename, Range}}
         when is_integer(HttpCode), HttpCode >= 200, HttpCode =< 999 ->
         {file, HttpCode, Headers, Filename, Range};
      %% Simple
      {HttpCode, Headers, Body}
         when is_integer(HttpCode), HttpCode >= 200, HttpCode =< 999 ->
         {response, HttpCode, Headers, Body};
      {HttpCode, Body}
         when is_integer(HttpCode), HttpCode >= 200, HttpCode =< 999 ->
         {response, HttpCode, [], Body};
      %% Unexpected
      Unexpected ->
         ?wsErr("handle return error WsReq:~p Ret:~p~n", [WsReq, Unexpected]),
         {response, 500, [], <<"Internal server error">>}
   catch
      throw:{ResponseCode, Headers, Body}
         when is_integer(ResponseCode), ResponseCode >= 200, ResponseCode =< 999 ->
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

%% Inject compression for normal responses.
%% 用户响应头只扫描一次，完成规范化、安全校验、框架自管头剔除和Connection语义提取。
doResponse({response, Code, UserHeaders0, Body}, Socket, ReqHeaders, Method, Version, ReqConn) ->
   {UserHeaders0a, UserClose} = prepareResponseHeaders(UserHeaders0),
   BodySize0 = iolist_size(Body),
   {SBody, UserHeaders1, BodySize} =
      tryCompressResponseSized(Body, BodySize0, UserHeaders0a, ReqHeaders, Code, Method),
   NHeaders = normalizeContentLength(Code, Method, BodySize, UserHeaders1),
   Policy = connectionPolicyPrepared(UserClose, ReqConn, Version),
   Headers = addConnectionHeaderPrepared(NHeaders, Policy, Version),
   case sendPreparedResponse(Socket, Method, Code, Headers, SBody) of
      ok -> Policy;
      _ -> close
   end;
doResponse({chunk, UserHeaders0, Initial}, Socket, _ReqHeaders, Method, Version, ReqConn) ->
   %% framing headers由框架生成；prepareResponseHeaders/1 同时完成安全校验。
   {UserHeaders, UserClose} = prepareResponseHeaders(UserHeaders0),
   Policy = connectionPolicyPrepared(UserClose, ReqConn, Version),
   ResponseHeaders = addConnectionHeaderPrepared(
      [{<<"Transfer-Encoding">>, <<"chunked">>} | UserHeaders], Policy, Version),
   case sendPreparedResponse(Socket, Method, 200, ResponseHeaders, <<>>) of
      ok ->
         case Method of
            'HEAD' ->
               Policy;
            _ ->
               %% 客户端在流式响应过程中断开时必须结束连接进程。
               %% 之前把 chunk loop 的结果丢掉、总是返回 keep-alive，进程会泄漏。
               %% sendChunk/2 本身正确处理空 iolist；不要用 orelse 连接其
               %% ok/{error,_} 返回值，否则非空 Initial 会触发 badarg。
               Sent = sendChunk(Socket, Initial),
               case Sent of
                  {error, _} ->
                     close;
                  _ ->
                     case startChunkLoop(Socket) of
                        ok -> Policy;
                        {error, _} -> close
                     end
               end
         end;
      _ ->
         close
   end;
%% WebSocket升级响应
doResponse({wsWebSocket, UserHeaders}, Socket, _ReqHeaders, _Method, _Version, _ReqConn) ->
   case sendResponse(Socket, 'GET', 101, normalizeH1Headers(UserHeaders), <<>>) of
      ok -> keep_ws;
      _ -> close
   end;
doResponse({file, ResponseCode, UserHeaders0, Filename, Range}, Socket, _ReqHeaders, Method, Version, ReqConn) ->
   %% 文件响应由框架确定长度/Range；用户头只扫描一次。
   {UserHeaders, UserClose} = prepareResponseHeaders(UserHeaders0),
   Policy = connectionPolicyPrepared(UserClose, ReqConn, Version),
   ResponseHeaders = addConnectionHeaderPrepared(UserHeaders, Policy, Version),
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
                     'HEAD' -> sendPreparedResponse(Socket, Method, ResponseCode, FileHeaders, <<>>);
                     _ -> sendPreparedFile(Socket, ResponseCode, FileHeaders, Filename, {0, 0})
                  end;
               {Offset, Length} ->
                  ERange = wsUtil:encodeRange({Offset, Length}, Size),
                  FileHeaders = [{<<"Content-Length">>, Length}, {<<"Content-Range">>, ERange} | ResponseHeaders],
                  case Method of
                     'HEAD' -> sendPreparedResponse(Socket, Method, 206, FileHeaders, <<>>);
                     _ -> sendPreparedFile(Socket, 206, FileHeaders, Filename, {Offset, Length})
                  end;
               invalid_range ->
                  ERange = wsUtil:encodeRange(invalid_range, Size),
                  sendPreparedResponse(Socket, Method, 416,
                     [{<<"Content-Length">>, 0}, {<<"Content-Range">>, ERange} | ResponseHeaders], <<>>)
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
   Body = responseBody(Method, Code, UserBody),
   Response = httpResponse(Code, Headers, Body),
   sendWireResponse(Socket, Response).

%% Normal-response hot path. Headers are already normalized and validated by
%% prepareResponseHeaders/1; framework-owned headers are trusted values.
sendPreparedResponse(Socket, Method, Code, Headers, UserBody) ->
   Body = responseBody(Method, Code, UserBody),
   Response = [
      <<"HTTP/1.1 ">>, status(Code), <<"\r\n">>,
      spellPreparedHeaders(Headers), <<"\r\n">>, Body
   ],
   sendWireResponse(Socket, Response).

sendWireResponse(Socket, Response) ->
   case wsNet:send(Socket, Response) of
      ok ->
         ok;
      {error, Reason} = Error
         when Reason =:= closed; Reason =:= econnreset; Reason =:= epipe;
              Reason =:= einval; Reason =:= enotconn ->
         ?wsWarn("send_response skipped, peer gone: ~p", [Reason]),
         Error;
      {error, Reason} = Error ->
         ?wsErr("send_response error ~p", [Reason]),
         Error
   end.

responseBody('HEAD', _Code, _UserBody) ->
   <<>>;
responseBody(_Method, Code, _UserBody) when Code >= 100, Code < 200 ->
   <<>>;
responseBody(_Method, 304, _UserBody) ->
   <<>>;
responseBody(_Method, 204, _UserBody) ->
   <<>>;
responseBody(_Method, 205, _UserBody) ->
   <<>>;
responseBody(_Method, _Code, UserBody) ->
   UserBody.
   %%case wsNet:send(Socket, Response) of
   %%   ok ->
   %%      ok;
   %%   {error, Reason} when Reason =:= closed; Reason =:= econnreset; Reason =:= epipe; Reason =:= einval ->
   %%      %% 对端在响应写完之前就断开：压测(如 wrk)收尾、浏览器提前导航、客户端主动 close 都会这样。
   %%      %% 这是正常事件而非服务端故障——连接状态机照常走 close。若按 ERROR 记，
   %%      %% 真实服务上这类日志会持续累积，把真正的写失败淹掉。
   %%      ?wsWarn("send_response skipped, peer gone: ~p~n", [Reason]),
   %%      {error, Reason};
   %%   _Err ->
   %%       ?wsErr("send_response error ~p~n", [_Err]),
   %%      _Err
   %%end.

%% helpers for compression
tryCompressResponse(Body, UserHeaders, ReqHeaders, Code, Method) ->
   BodySize = iolist_size(Body),
   {SBody, SHeaders, _Size} =
      tryCompressResponseSized(Body, BodySize, UserHeaders, ReqHeaders, Code, Method),
   {SBody, SHeaders}.

tryCompressResponseSized(Body, BodySize, UserHeaders, ReqHeaders, Code, Method) ->
   Skip = (Method =:= 'HEAD') orelse (Code =:= 204) orelse (Code =:= 205)
      orelse (Code =:= 304) orelse BodySize < 1024,
   case Skip of
      true ->
         {Body, UserHeaders, BodySize};
      false ->
         case findHeader(<<"Content-Encoding">>, UserHeaders) of
            false ->
               case chooseContentEncoding(ReqHeaders) of
                  none ->
                     {Body, UserHeaders, BodySize};
                  gzip ->
                     CBody = zlib:gzip(iolist_to_binary(Body)),
                     {CBody, addVary([{<<"Content-Encoding">>, <<"gzip">>} | UserHeaders]), byte_size(CBody)};
                  deflate ->
                     CBody = zlib:compress(iolist_to_binary(Body)),
                     {CBody, addVary([{<<"Content-Encoding">>, <<"deflate">>} | UserHeaders]), byte_size(CBody)}
               end;
            _ ->
               {Body, UserHeaders, BodySize}
         end
   end.

chooseContentEncoding(ReqHeaders) ->
   %% decode_packet/H2 compatibility layer both expose the standard header as
   %% 'Accept-Encoding'. Common path is a single keyfind; binary fallback keeps
   %% compatibility with hand-built request records.
   Header = case lists:keyfind('Accept-Encoding', 1, ReqHeaders) of
      {_, _} = Found -> Found;
      false -> findHeader(<<"Accept-Encoding">>, ReqHeaders)
   end,
   case Header of
      false ->
         none;
      {_, Value0} ->
         {GzipQ, DeflateQ} = acceptEncodingQ(iolist_to_binary(Value0)),
         case {GzipQ, DeflateQ} of
            {G, D} when G > 0, G >= D -> gzip;
            {_G, D} when D > 0 -> deflate;
            _ -> none
         end
   end.

acceptEncodingQ(Value) ->
   Tokens = binary:split(Value, <<",">>, [global]),
   {G0, D0, Star, GSeen, DSeen} =
      acceptEncodingQ(Tokens, 0, 0, 0, false, false),
   G = case GSeen of true -> G0; false -> Star end,
   D = case DSeen of true -> D0; false -> Star end,
   {G, D}.

acceptEncodingQ([], G, D, Star, GSeen, DSeen) ->
   {G, D, Star, GSeen, DSeen};
acceptEncodingQ([Token0 | Rest], G, D, Star, GSeen, DSeen) ->
   Parts = binary:split(Token0, <<";">>, [global]),
   [Name0 | Params] = Parts,
   Name = string:trim(Name0),
   Q = parseEncodingQ(Params),
   case true of
      _ when GSeen =:= false ->
         case wsUtil:headerNameEq(Name, <<"gzip">>) of
            true -> acceptEncodingQ(Rest, Q, D, Star, true, DSeen);
            false -> acceptEncodingQOther(Name, Q, Rest, G, D, Star, GSeen, DSeen)
         end;
      _ ->
         acceptEncodingQOther(Name, Q, Rest, G, D, Star, GSeen, DSeen)
   end.

acceptEncodingQOther(Name, Q, Rest, G, D, Star, GSeen, DSeen) ->
   case {DSeen, wsUtil:headerNameEq(Name, <<"deflate">>)} of
      {false, true} ->
         acceptEncodingQ(Rest, G, Q, Star, GSeen, true);
      _ ->
         case wsUtil:headerNameEq(Name, <<"*">>) of
            true -> acceptEncodingQ(Rest, G, D, Q, GSeen, DSeen);
            false -> acceptEncodingQ(Rest, G, D, Star, GSeen, DSeen)
         end
   end.

parseEncodingQ([]) ->
   1000;
parseEncodingQ([Param | Rest]) ->
   case binary:split(Param, <<"=">>) of
      [K, V] ->
         case wsUtil:headerNameEq(string:trim(K), <<"q">>) of
            true -> qValue(string:trim(V));
            false -> parseEncodingQ(Rest)
         end;
      _ ->
         parseEncodingQ(Rest)
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


addVary(Hs) ->
   case findHeader(<<"Vary">>, Hs) of
      false ->
         [{<<"Vary">>, <<"Accept-Encoding">>} | Hs];
      {Key, Value} ->
         case lists:any(
            fun(T) -> wsUtil:headerNameEq(string:trim(T), <<"Accept-Encoding">>) end,
            binary:split(iolist_to_binary(Value), <<",">>, [global])
         ) of
            true -> Hs;
            false -> lists:keyreplace(Key, 1, Hs, {Key, [Value, <<", Accept-Encoding">>]})
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

sendPreparedFile(Socket, Code, Headers, Filename, Range) ->
   ResponseHeaders = [
      <<"HTTP/1.1 ">>, status(Code), <<"\r\n">>,
      spellPreparedHeaders(Headers), <<"\r\n">>
   ],
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
            {ok, _BytesSent} ->
               ok;
            {error, Reason} = Error ->
               ?wsErr("send file error ~p", [Reason]),
               Error
         end;
      {error, Reason} = Error ->
         ?wsErr("send file header error ~p", [Reason]),
         Error
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
   %% Streaming期间只预读一个客户端包：既能在空闲时及时收到 *_closed，
   %% 又不会因为客户端持续pipeline而无限把请求数据搬进本进程mailbox。
   %% 一旦收到数据，{active,1} 自动转回passive，内核接收缓冲自然形成背压。
   wsNet:setopts(Socket, [{active, 1}]),
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
         %% 不在stream期间继续re-arm；否则未匹配的pipeline数据会无界堆mailbox。
         ?MODULE:chunkLoop(Socket);
      {ssl_passive, Socket} ->
         ?MODULE:chunkLoop(Socket);
      {chunk, close} ->
         case wsNet:send(Socket, <<"0\r\n\r\n">>) of
            ok ->
               _ = wsNet:setopts(Socket, [{active, ?ActionN}]),
               ok;
            {error, _Reason} ->
               {error, client_closed}
         end;
      {chunk, close, From} ->
         case wsNet:send(Socket, <<"0\r\n\r\n">>) of
            ok ->
               _ = wsNet:setopts(Socket, [{active, ?ActionN}]),
               From ! {self(), ok},
               ok;
            {error, _Reason} ->
               From ! {self(), {error, closed}},
               {error, client_closed}
         end;
      {chunk, Data} ->
         case sendChunk(Socket, Data) of
            ok -> ?MODULE:chunkLoop(Socket);
            {error, _} -> {error, client_closed}
         end;
      {chunk, Data, From} ->
         case sendChunk(Socket, Data) of
            ok ->
               From ! {self(), ok},
               ?MODULE:chunkLoop(Socket);
            {error, _} ->
               From ! {self(), {error, closed}},
               {error, client_closed}
         end
   end.

sendChunk(Socket, Data) ->
   case iolist_size(Data) of
      0 -> ok;
      Size ->
         Response = [integer_to_binary(Size, 16), <<"\r\n">>, Data, <<"\r\n">>],
         wsNet:send(Socket, Response)
   end.

maybeSendContinue(Socket, Headers) ->
   %% decode_packet 已知头表不含 Expect，未收录头以 binary 键返回。
   case getExpect(Headers) of
      undefined ->
         ok;
      Value ->
         case wsUtil:headerNameEq(string:trim(iolist_to_binary(Value)), <<"100-continue">>) of
            true ->
               wsNet:send(Socket, httpResponse(100));
            false ->
               {error, unsupported_expectation}
         end
   end.

getExpect(Headers) ->
   case findHeader(<<"Expect">>, Headers) of
      false -> undefined;
      {_, Value} -> Value
   end.

httpResponse(Code) ->
   httpResponse(Code, <<>>).

httpResponse(Code, Body) ->
   httpResponse(Code, [{<<"Content-Length">>, size(Body)}], Body).

httpResponse(Code, Headers, Body) ->
   [<<"HTTP/1.1 ">>, status(Code), <<"\r\n">>, spellHeaders(Headers), <<"\r\n">>, Body].

spellHeaders(Headers) ->
   [[Name, <<": ">>, Value, <<"\r\n">>]
      || Header <- Headers,
         {ok, Name, Value} <- [wireHeader(Header)]].

spellPreparedHeaders(Headers) ->
   [[Name, <<": ">>, preparedHeaderValue(Value), <<"\r\n">>] || {Name, Value} <- Headers].

preparedHeaderValue(Value) when is_binary(Value) -> Value;
preparedHeaderValue(Value) when is_integer(Value) -> integer_to_binary(Value);
preparedHeaderValue(Value) when is_atom(Value) -> atom_to_binary(Value);
preparedHeaderValue(Value) when is_list(Value) -> iolist_to_binary(Value).

%% 热路径：handler / 框架给出的头几乎全是 binary，走无 try 的快路径。
wireHeader({Name, Value}) when is_binary(Name), is_binary(Value), Name =/= <<>> ->
   case validH1HeaderName(Name) andalso validH1HeaderValue(Value) of
      true -> {ok, Name, Value};
      false ->
         ?wsWarn("ignore invalid HTTP/1 response header name=~p", [Name]),
         invalid
   end;
wireHeader({Key0, Value0}) when Key0 =/= <<>>, Key0 =/= '' ->
   try
      Name = toBinStr(Key0),
      Value = toBinStr(Value0),
      case validH1HeaderName(Name) andalso validH1HeaderValue(Value) of
         true -> {ok, Name, Value};
         false ->
            ?wsWarn("ignore invalid HTTP/1 response header name=~p", [Name]),
            invalid
      end
   catch
      _:_ -> invalid
   end;
wireHeader(_) ->
   invalid.

validH1HeaderName(<<>>) ->
   false;
validH1HeaderName(Bin) ->
   validH1HeaderNameChars(Bin).

%% guard 逐字节判 token 实测比查表快，保持不动。
validH1HeaderNameChars(<<>>) ->
   true;
validH1HeaderNameChars(<<C, Rest/binary>>) when
   (C >= 65 andalso C =< 90) orelse
   (C >= 97 andalso C =< 122) orelse
   (C >= 48 andalso C =< 57) orelse
   C =:= 33 orelse C =:= 35 orelse C =:= 36 orelse C =:= 37 orelse
   C =:= 38 orelse C =:= 39 orelse C =:= 42 orelse C =:= 43 orelse
   C =:= 45 orelse C =:= 46 orelse C =:= 94 orelse C =:= 95 orelse
   C =:= 96 orelse C =:= 124 orelse C =:= 126 ->
   validH1HeaderNameChars(Rest);
validH1HeaderNameChars(_) ->
   false.

validH1HeaderValue(Value) ->
   wsUtil:noCtlChars(Value).

%% 响应头键统一成 binary，便于后续 keydelete / keyfind。
%% 绝大多数 handler 已直接返回 binary key；这种常见情况原样复用列表，
%% 避免每个响应都重新分配一份 header list。
normalizeH1Headers(Headers) ->
   case binaryHeaderNames(Headers) of
      true -> Headers;
      false -> [{toBinStr(Key), Value} || {Key, Value} <- Headers]
   end.

binaryHeaderNames([]) ->
   true;
binaryHeaderNames([{Key, _Value} | Rest]) when is_binary(Key) ->
   binaryHeaderNames(Rest);
binaryHeaderNames(_) ->
   false.

%% One-pass preparation for ordinary responses: normalize and validate user
%% headers, drop framing headers owned by the server, and extract Connection.
prepareResponseHeaders(Headers) ->
   prepareResponseHeaders(Headers, false, []).

prepareResponseHeaders([], HasClose, Acc) ->
   {lists:reverse(Acc), HasClose};
prepareResponseHeaders([{Key0, Value0} | Rest], HasClose, Acc) ->
   try
      Name = toBinStr(Key0),
      Value = toBinStr(Value0),
      case validH1HeaderName(Name) andalso validH1HeaderValue(Value) of
         false ->
            ?wsWarn("ignore invalid HTTP/1 response header name=~p", [Name]),
            prepareResponseHeaders(Rest, HasClose, Acc);
         true ->
            case managedResponseHeader(Name) of
               content_length ->
                  prepareResponseHeaders(Rest, HasClose, Acc);
               transfer_encoding ->
                  prepareResponseHeaders(Rest, HasClose, Acc);
               connection ->
                  prepareResponseHeaders(
                     Rest,
                     HasClose orelse headerValueHasToken(Value, <<"close">>),
                     Acc
                  );
               normal ->
                  prepareResponseHeaders(Rest, HasClose, [{Name, Value} | Acc])
            end
      end
   catch
      _:_ ->
         prepareResponseHeaders(Rest, HasClose, Acc)
   end;
prepareResponseHeaders([_ | Rest], HasClose, Acc) ->
   prepareResponseHeaders(Rest, HasClose, Acc).

managedResponseHeader(Name) when byte_size(Name) =:= 10 ->
   case wsUtil:headerNameEq(Name, <<"Connection">>) of
      true -> connection;
      false -> normal
   end;
managedResponseHeader(Name) when byte_size(Name) =:= 14 ->
   case wsUtil:headerNameEq(Name, <<"Content-Length">>) of
      true -> content_length;
      false -> normal
   end;
managedResponseHeader(Name) when byte_size(Name) =:= 17 ->
   case wsUtil:headerNameEq(Name, <<"Transfer-Encoding">>) of
      true -> transfer_encoding;
      false -> normal
   end;
managedResponseHeader(_Name) ->
   normal.

%% header 名按 RFC 7230 大小写不敏感。旧实现每次 toLowerStr 分配临时 binary，
%% 响应热路径上每请求十余次查找，吃掉约 15~20% 吞吐。
%% 现在：先 lists:keyfind（BIF，规范大小写时直接命中），未命中再零分配 CI 比较。
deleteHeader(Name, Headers) ->
   lists:filter(fun
      ({Key, _}) -> not wsUtil:headerNameEq(Key, Name);
      (_) -> true
   end, Headers).

findHeader(Name, Headers) ->
   case lists:keyfind(Name, 1, Headers) of
      {_, _} = Found -> Found;
      false -> findHeaderCi(Name, Headers)
   end.

findHeaderCi(_Name, []) ->
   false;
findHeaderCi(Name, [{Key, Value} | Rest]) ->
   case wsUtil:headerNameEq(Key, Name) of
      true -> {Key, Value};
      false -> findHeaderCi(Name, Rest)
   end;
findHeaderCi(Name, [_ | Rest]) ->
   findHeaderCi(Name, Rest).

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

%% HTTP/1.1 下 keep-alive 是默认，不必再解析 Connection: keep-alive。
connectionPolicy(UserHeaders, ReqHeaders, Version) ->
   case headerHasToken(<<"Connection">>, UserHeaders, <<"close">>)
        orelse requestHeaderHasToken('Connection', ReqHeaders, <<"close">>) of
      true ->
         close;
      false when Version =:= {1, 0} ->
         case requestHeaderHasToken('Connection', ReqHeaders, <<"keep-alive">>) of
            true -> keep_alive;
            false -> close
         end;
      false ->
         keep_alive
   end.

connectionPolicyPrepared(true, _ReqConn, _Version) ->
   close;
connectionPolicyPrepared(false, {true, _ReqKeepAlive}, _Version) ->
   close;
connectionPolicyPrepared(false, {false, true}, {1, 0}) ->
   keep_alive;
connectionPolicyPrepared(false, {false, false}, {1, 0}) ->
   close;
connectionPolicyPrepared(false, _ReqConn, _Version) ->
   keep_alive.

addConnectionHeaderPrepared(Headers, close, _Version) ->
   [{<<"Connection">>, <<"close">>} | Headers];
addConnectionHeaderPrepared(Headers, keep_alive, {1, 0}) ->
   [{<<"Connection">>, <<"Keep-Alive">>} | Headers];
addConnectionHeaderPrepared(Headers, keep_alive, _Version) ->
   Headers.

addConnectionHeader(Headers0, Policy, Version) ->
   Headers = deleteHeader(<<"Connection">>, Headers0),
   case {Policy, Version} of
      {close, _} -> [{<<"Connection">>, <<"close">>} | Headers];
      {keep_alive, {1, 0}} -> [{<<"Connection">>, <<"Keep-Alive">>} | Headers];
      {keep_alive, _} -> Headers
   end.

%% decode_packet(httph_bin, ...) 会把 Connection 这类标准字段规范成 atom。
%% 请求热路径因此直接 keyfind，不再在缺失时做逐项大小写扫描。
requestHeaderHasToken(Name, Headers, Wanted) ->
   case lists:keyfind(Name, 1, Headers) of
      false -> false;
      {_, Value} -> headerValueHasToken(Value, Wanted)
   end.

headerHasToken(Name, Headers, Wanted) ->
   case findHeader(Name, Headers) of
      false -> false;
      {_, Value} -> headerValueHasToken(Value, Wanted)
   end.

headerValueHasToken(Value, Wanted) ->
   %% 不整串 toLowerStr：按逗号切开后对每个 token 做零分配 CI 比较。
   Tokens = binary:split(iolist_to_binary(Value), <<",">>, [global]),
   lists:any(fun(T) -> wsUtil:headerNameEq(string:trim(T), Wanted) end, Tokens).

%% HTTP STATUS CODES
status(100) -> <<"100 Continue">>;
status(101) -> <<"101 Switching Protocols">>;
status(102) -> <<"102 Processing">>;
status(103) -> <<"103 Early Hints">>;
status(200) -> <<"200 OK">>;
status(201) -> <<"201 Created">>;
status(202) -> <<"202 Accepted">>;
status(203) -> <<"203 Non-Authoritative Information">>;
status(204) -> <<"204 No Content">>;
status(205) -> <<"205 Reset Content">>;
status(206) -> <<"206 Partial Content">>;
status(207) -> <<"207 Multi-Status">>;
status(208) -> <<"208 Already Reported">>;
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
status(421) -> <<"421 Misdirected Request">>;
status(422) -> <<"422 Unprocessable Entity">>;
status(423) -> <<"423 Locked">>;
status(424) -> <<"424 Failed Dependency">>;
status(425) -> <<"425 Unordered Collection">>;
status(426) -> <<"426 Upgrade Required">>;
status(428) -> <<"428 Precondition Required">>;
status(429) -> <<"429 Too Many Requests">>;
status(431) -> <<"431 Request Header Fields Too Large">>;
status(451) -> <<"451 Unavailable For Legal Reasons">>;
status(500) -> <<"500 Internal Server Error">>;
status(501) -> <<"501 Not Implemented">>;
status(502) -> <<"502 Bad Gateway">>;
status(503) -> <<"503 Service Unavailable">>;
status(504) -> <<"504 Gateway Timeout">>;
status(505) -> <<"505 HTTP Version Not Supported">>;
status(506) -> <<"506 Variant Also Negotiates">>;
status(507) -> <<"507 Insufficient Storage">>;
status(508) -> <<"508 Loop Detected">>;
status(510) -> <<"510 Not Extended">>;
status(511) -> <<"511 Network Authentication Required">>;
status(I) when is_integer(I), I >= 100, I < 1000 ->
   <<(integer_to_binary(I))/binary, " Unknown">>.
