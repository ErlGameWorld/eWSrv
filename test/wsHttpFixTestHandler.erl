-module(wsHttpFixTestHandler).

-include("eWSrv.hrl").

-export([
   handle/3
   , init/1
   , handleCall/3
   , handleCast/2
   , handleInfo/2
]).

init(_Args) ->
   put(ws_http_fix_handler_initialized, true),
   {ok, initialized}.

handle('GET', <<"/hello">>, _Req) ->
   {ok, [{<<"Content-Type">>, <<"text/plain">>}], <<"Hello, World!">>};
handle('GET', <<"/init-state">>, _Req) ->
   Body = case get(ws_http_fix_handler_initialized) of
      true -> <<"initialized">>;
      _ -> <<"not-initialized">>
   end,
   {ok, [{<<"Content-Type">>, <<"text/plain">>}], Body};
handle('GET', <<"/codefile">>, _Req) ->
   Path = filename:join(code:priv_dir(eWSrv), "server_cert.pem"),
   {200, [{<<"Content-Type">>, <<"text/plain">>}], {file, Path}};
handle('GET', <<"/missingfile">>, _Req) ->
   {ok, [], {file, "C:/definitely/not/here.txt"}};
handle('GET', <<"/chunk-initial">>, _Req) ->
   Conn = self(),
   spawn(fun() -> Conn ! {chunk, close} end),
   {chunk, [{<<"Content-Type">>, <<"text/plain">>}], <<"hello">>};
handle('GET', <<"/chunk-te">>, _Req) ->
   Conn = self(),
   spawn(fun() ->
      Conn ! {chunk, <<"x">>},
      Conn ! {chunk, close}
   end),
   {chunk, [{<<"Transfer-Encoding">>, <<"gzip">>}]};
handle('GET', <<"/unsafe-headers">>, _Req) ->
   {200, [
      {<<"X-Good">>, <<"ok">>},
      {<<"X-Bad\r\nX-Injected">>, <<"yes">>},
      {<<"X-Value">>, <<"ok\r\nX-Injected: yes">>},
      {<<"X-Ctl">>, <<1>>}
   ], <<"safe">>};
handle('GET', <<"/informational-final">>, _Req) ->
   %% Handler API returns one final response only. 1xx requires a separate
   %% informational-response API, so this shape must be rejected by the engine.
   {103, [{<<"Link">>, <<"</style.css>; rel=preload">>}], <<"must-not-be-final">>};
handle('GET', <<"/bad-status">>, _Req) ->
   %% 故意的非法形状：首元素本该是整数状态码，这里塞了一个带 CRLF 的二进制。
   %% 服务器必须拒绝它、落到 500，并打一条 ERROR 级 "handle return error"
   %% 日志（见 src/wsSrv/wsHttp.erl 的 Unexpected 分支）。
   %% 所以 eunit 输出里那条 ERROR REPORT 是预期噪音，不代表测试失败。
   {<<"200 OK\r\nX-Injected: yes">>, [], <<"unsafe">>};
handle('GET', <<"/lowercase-headers">>, _Req) ->
   %% Header field names are case-insensitive. The server must replace these
   %% semantic fields instead of emitting duplicate Content-Length/Connection.
   {ok, [
      {<<"content-length">>, <<"999">>},
      {<<"connection">>, <<"close">>},
      {<<"vary">>, <<"Origin">>}
   ], <<"abc">>};
handle('POST', <<"/echo">>, #wsReq{body = Body}) ->
   {ok, [{<<"Content-Type">>, <<"text/plain">>}], Body};
handle(_, _, _) ->
   {404, [], <<"Not Found">>}.

%% behaviour 回调默认实现：忽略该类消息，WebState 保持不变。
%% 引擎在 is_behavior = true 时无条件调用这三个（不做 function_exported 检查），所以必须存在。
handleCall(_Request, _WebState, _From) ->
   kpS.

handleCast(_Request, _WebState) ->
   kpS.

handleInfo(_Info, _WebState) ->
   kpS.
