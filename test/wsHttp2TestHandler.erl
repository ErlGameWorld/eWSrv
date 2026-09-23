-module(wsHttp2TestHandler).

-include("eWSrv.hrl").

-export([
   handle/3
   , handleCall/3
   , handleCast/2
   , handleInfo/2
]).

handle('GET', <<"/one">>, _Req) ->
   {ok, [{<<"content-type">>, <<"text/plain">>}], <<"one">>};
handle('GET', <<"/two">>, _Req) ->
   {ok, [{<<"content-type">>, <<"text/plain">>}], <<"two">>};
handle('GET', <<"/slow">>, _Req) ->
   timer:sleep(500),
   {ok, [{<<"content-type">>, <<"text/plain">>}], <<"slow">>};
handle('GET', <<"/1k">>, _Req) ->
   {ok, [{<<"content-type">>, <<"application/octet-stream">>}], benchBody(body_1k, 1024)};
handle('GET', <<"/large">>, _Req) ->
   {ok, [{<<"content-type">>, <<"application/octet-stream">>}], benchBody(body_100k, 100000)};
handle('GET', <<"/1m">>, _Req) ->
   {ok, [{<<"content-type">>, <<"application/octet-stream">>}], benchBody(body_1m, 1024 * 1024)};
handle('GET', <<"/reset-content">>, _Req) ->
   {205, [{<<"content-type">>, <<"text/plain">>}], <<"must-not-be-sent">>};
handle('POST', <<"/echo">>, #wsReq{body = Body}) ->
   {ok, [{<<"content-type">>, <<"application/octet-stream">>}], Body};
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

%% Benchmark payloads are allocated once during warm-up. Reusing the same
%% immutable binary keeps handler allocation out of HTTP stack measurements.
benchBody(Key, Size) ->
   PKey = {?MODULE, Key},
   case persistent_term:get(PKey, undefined) of
      undefined ->
         Body = binary:copy(<<"x">>, Size),
         persistent_term:put(PKey, Body),
         Body;
      Body ->
         Body
   end.
