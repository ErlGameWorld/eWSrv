-module(wsHer).

-include("eWSrv.hrl").

-export_type([
   response/0
   , wsResponse/0
]).

-type response() ::
   {wsHttpCode() | ok, wsBody()}|
   {wsHttpCode() | ok, wsHeaders(), wsBody()}|
   {wsHttpCode() | ok, wsHeaders(), {file, file:name_all()}|
   {file, file:name_all(), wsUtil:range()}}|
   {chunk, wsHeaders()}|
   {chunk, wsHeaders(), wsBody()} |
   {wsUpgrade, wsHeaders()}.

-callback handle(Method :: wsMethod(), Path :: binary(), Req :: wsReq()) -> response().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%websocket%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-type wsResponse() ::
   {ok, WsOpCode :: wsOpCode(), Data :: binary(), WebState :: term()} |
   {ok, WebState :: term()} |
   {close, WebState :: term()} |
   {close, Reason :: term(), WebState :: term()} |
   {stop, Reason :: term(), WebState :: term()}.
-callback handleWs(WsOpCode :: wsOpCode(), Data :: binary(), WebState :: term()) -> wsResponse().

-callback init(Args :: term()) -> {ok, State :: term()} |{stop, Reason :: term()}.
-callback handleCall(Request :: term(), State :: term(), From :: {pid(), Tag :: term()}) ->
   kpS |
   {reply, Reply :: term()} |
   {reply, Reply :: term(), NewState :: term()} |
   {noreply, NewState :: term()} |
   {mayReply, Reply :: term()} |
   {mayReply, Reply :: term(), NewState :: term()} |
   {stop, Reason :: term(), NewState :: term()} |
   {stopReply, Reason :: term(), Reply :: term(), NewState :: term()}.

-callback handleCast(Request :: term(), State :: term()) ->
   kpS |
   {noreply, NewState :: term()} |
   {stop, Reason :: term(), NewState :: term()}.

-callback handleInfo(Info :: timeout | term(), State :: term()) ->
   kpS |
   {noreply, NewState :: term()} |
   {stop, Reason :: term(), NewState :: term()}.

-callback terminate(Reason :: timeout, WebState :: timeout) -> ignore.

%% 支持的WebSocket协议
-callback supportedProtocols() -> [binary()].
%% 支持的WebSocket扩展
-callback supportedExtensions() -> [binary()].

%% 与引擎侧的实际调用方式对齐：
%%   init/1、terminate/2、handleWs/3 —— 调用前会先做 function_exported 检查，属可选；
%%   handleCall/3、handleCast/2、handleInfo/2 —— is_behavior = true 时无条件调用，属必需，
%%      默认 handler wsTPHer 已提供「忽略」实现，业务 handler 自行覆盖；
%%   supportedProtocols/0 —— WebSocket握手时用于子协议协商，属可选；
%%   supportedExtensions/0 —— 预留接口，扩展帧语义尚未启用，属可选。
-optional_callbacks([init/1, handleWs/3, terminate/2, supportedProtocols/0, supportedExtensions/0]).