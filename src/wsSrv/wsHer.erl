-module(wsHer).

-include("eWSrv.hrl").

-export_type([
	response/0
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
-callback handleMsg(WsOpCode :: wsOpCode(), Data :: binary(), WebState :: term()) -> wsResponse().

%% 升级之后调用 可以其他玩家进程之类的
-callback onWsUpgrade(wsReq()) -> term().
%% 支持的WebSocket协议
-callback supportedProtocols() -> [binary()].
%% 支持的WebSocket扩展
-callback supportedExtensions() -> [binary()].

-optional_callbacks([onWsUpgrade/1, handleMsg/3, supportedProtocols/0, supportedExtensions/0]).