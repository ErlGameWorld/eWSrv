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
{ok, WebState :: term()}.
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

%% 支持的WebSocket协议
-callback supportedProtocols() -> [binary()].
%% 支持的WebSocket扩展
-callback supportedExtensions() -> [binary()].

-optional_callbacks([init/1, handleCall/3, handleCast/2, handleInfo/2, handleWs/3, supportedProtocols/0, supportedExtensions/0]).