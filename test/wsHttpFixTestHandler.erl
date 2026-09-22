-module(wsHttpFixTestHandler).

-include("eWSrv.hrl").

-export([handle/3]).

handle('GET', <<"/hello">>, _Req) ->
   {ok, [{<<"Content-Type">>, <<"text/plain">>}], <<"Hello, World!">>};
handle('GET', <<"/codefile">>, _Req) ->
   Path = filename:join(code:priv_dir(eWSrv), "server_cert.pem"),
   {200, [{<<"Content-Type">>, <<"text/plain">>}], {file, Path}};
handle('GET', <<"/missingfile">>, _Req) ->
   {ok, [], {file, "C:/definitely/not/here.txt"}};
handle('POST', <<"/echo">>, #wsReq{body = Body}) ->
   {ok, [{<<"Content-Type">>, <<"text/plain">>}], Body};
handle(_, _, _) ->
   {404, [], <<"Not Found">>}.
