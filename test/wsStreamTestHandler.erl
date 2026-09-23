-module(wsStreamTestHandler).

-include_lib("eWSrv/include/eWSrv.hrl").

-export([
   handle/3
   , handleCall/3
   , handleCast/2
   , handleInfo/2
]).

handle('GET', <<"/disconnect">>, _Req) ->
   Conn = self(),
   Owner = whereis(ws_stream_test_owner),
   spawn(fun() -> watchConnection(Owner, Conn) end),
   {chunk, [{<<"Content-Type">>, <<"text/event-stream">>}], <<": ready\n\n">>};
handle('GET', <<"/finite">>, _Req) ->
   Conn = self(),
   spawn(fun() ->
      Conn ! {chunk, <<"done">>},
      Conn ! {chunk, close}
   end),
   {chunk, [{<<"Content-Type">>, <<"text/plain">>}]};
handle('GET', <<"/delayed-finite">>, _Req) ->
   Conn = self(),
   spawn(fun() ->
      timer:sleep(100),
      Conn ! {chunk, <<"done">>},
      Conn ! {chunk, close}
   end),
   {chunk, [{<<"Content-Type">>, <<"text/plain">>}]};
handle('GET', <<"/hello">>, _Req) ->
   {200, [{<<"Content-Type">>, <<"text/plain">>}], <<"hello">>};
handle(_, _, _Req) ->
   {404, [], <<"not found">>}.

%% behaviour 回调默认实现：忽略该类消息，WebState 保持不变。
%% 引擎在 is_behavior = true 时无条件调用这三个（不做 function_exported 检查），所以必须存在。
handleCall(_Request, _WebState, _From) ->
   kpS.

handleCast(_Request, _WebState) ->
   kpS.

handleInfo(_Info, _WebState) ->
   kpS.

watchConnection(Owner, Conn) ->
   Ref = erlang:monitor(process, Conn),
   Owner ! {stream_connection, Conn},
   receive
      {'DOWN', Ref, process, Conn, Reason} ->
         Owner ! {stream_connection_down, Conn, Reason}
   after 2000 ->
      Owner ! {stream_connection_leaked, Conn}
   end.
