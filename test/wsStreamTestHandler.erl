-module(wsStreamTestHandler).

-include_lib("eWSrv/include/eWSrv.hrl").

-export([handle/3]).

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
handle('GET', <<"/hello">>, _Req) ->
   {200, [{<<"Content-Type">>, <<"text/plain">>}], <<"hello">>};
handle(_, _, _Req) ->
   {404, [], <<"not found">>}.

watchConnection(Owner, Conn) ->
   Ref = erlang:monitor(process, Conn),
   Owner ! {stream_connection, Conn},
   receive
      {'DOWN', Ref, process, Conn, Reason} ->
         Owner ! {stream_connection_down, Conn, Reason}
   after 2000 ->
      Owner ! {stream_connection_leaked, Conn}
   end.
