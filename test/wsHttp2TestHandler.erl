-module(wsHttp2TestHandler).

-include("eWSrv.hrl").

-export([handle/3]).

handle('GET', <<"/one">>, _Req) ->
   {ok, [{<<"content-type">>, <<"text/plain">>}], <<"one">>};
handle('GET', <<"/two">>, _Req) ->
   {ok, [{<<"content-type">>, <<"text/plain">>}], <<"two">>};
handle('GET', <<"/slow">>, _Req) ->
   timer:sleep(500),
   {ok, [{<<"content-type">>, <<"text/plain">>}], <<"slow">>};
handle('GET', <<"/large">>, _Req) ->
   {ok, [{<<"content-type">>, <<"application/octet-stream">>}],
      binary:copy(<<"x">>, 100000)};
handle('GET', <<"/reset-content">>, _Req) ->
   {205, [{<<"content-type">>, <<"text/plain">>}], <<"must-not-be-sent">>};
handle('POST', <<"/echo">>, #wsReq{body = Body}) ->
   {ok, [{<<"content-type">>, <<"application/octet-stream">>}], Body};
handle(_, _, _) ->
   {404, [], <<"Not Found">>}.
