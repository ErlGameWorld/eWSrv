-module(wsHttpFixTests).

-include_lib("eunit/include/eunit.hrl").
-include("wsCom.hrl").

%% ============================================================================
%% Unit: normalizeRange / status / spellHeaders
%% ============================================================================

normalize_range_whole_file_test() ->
   ?assertEqual(undefined, wsUtil:normalizeRange([], 100)),
   ?assertEqual(undefined, wsUtil:normalizeRange({0, 0}, 100)),
   ?assertEqual({10, 90}, wsUtil:normalizeRange({offset, 10}, 100)),
   ?assertEqual({40, 20}, wsUtil:normalizeRange({bytes, 40, 59}, 100)),
   ?assertEqual({80, 20}, wsUtil:normalizeRange({suffix, 20}, 100)),
   ?assertEqual(invalid_range, wsUtil:normalizeRange({200, 10}, 100)).

status_reason_phrase_has_space_test() ->
   lists:foreach(fun(Code) ->
      Line = wsHttp:status(Code),
      <<Digits:3/binary, 32, _Rest/binary>> = Line,
      ?assertEqual(integer_to_binary(Code), Digits)
   end, [103, 200, 208, 299, 418, 421, 451, 508, 999]).

spell_headers_accepts_atom_keys_test() ->
   Io = wsHttp:spellHeaders([
      {'Content-Type', <<"text/plain">>},
      {<<"X-Custom">>, <<"v">>}
   ]),
   Bin = iolist_to_binary(Io),
   ?assertEqual(<<"Content-Type: text/plain\r\nX-Custom: v\r\n">>, Bin).

%% ============================================================================
%% End-to-end: Expect / file response / missing file
%% ============================================================================

expect_100_continue_test_() ->
   {timeout, 10, fun expect100Continue/0}.

expect100Continue() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"POST /echo HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\n">>,
         <<"Content-Length: 5\r\n">>,
         <<"Expect: 100-continue\r\n">>,
         <<"\r\n">>
      ]),
      {ok, Cont} = gen_tcp:recv(Sock, 0, 2000),
      ?assertMatch(<<"HTTP/1.1 100 Continue", _/binary>>, Cont),
      ok = gen_tcp:send(Sock, <<"hello">>),
      {ok, Resp} = gen_tcp:recv(Sock, 0, 2000),
      ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Resp),
      ?assert(binary:match(Resp, <<"hello">>) =/= nomatch),
      gen_tcp:close(Sock)
   end).

codefile_keeps_body_length_in_sync_test_() ->
   {timeout, 10, fun codefileKeepAlive/0}.

codefileKeepAlive() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /codefile HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\n">>,
         <<"Connection: keep-alive\r\n">>,
         <<"\r\n">>,
         <<"GET /hello HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\n">>,
         <<"Connection: close\r\n">>,
         <<"\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      {Status1, Headers1, Body1, Rest1} = takeResponse(Bin),
      ?assertEqual(200, Status1),
      ?assertEqual(false, lists:keyfind(<<"Content-Range">>, 1, Headers1)),
      {_, LenBin} = lists:keyfind(<<"Content-Length">>, 1, Headers1),
      ?assertEqual(binary_to_integer(LenBin), byte_size(Body1)),
      ?assertMatch(<<"-----BEGIN CERTIFICATE-----", _/binary>>, Body1),
      {Status2, _Headers2, Body2, _} = takeResponse(Rest1),
      ?assertEqual(200, Status2),
      ?assertEqual(<<"Hello, World!">>, Body2),
      gen_tcp:close(Sock)
   end).

missing_file_returns_500_without_crash_test_() ->
   {timeout, 10, fun missingFile/0}.

missingFile() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /missingfile HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\n">>,
         <<"Connection: close\r\n">>,
         <<"\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      {Status, _Headers, _Body, _} = takeResponse(Bin),
      ?assertEqual(500, Status),
      gen_tcp:close(Sock)
   end).

%% ============================================================================
%% Helpers
%% ============================================================================

withServer(Fun) ->
   {ok, _} = application:ensure_all_started(eWSrv),
   Name = list_to_atom("ws_http_fix_" ++ integer_to_list(erlang:unique_integer([positive]))),
   Port = freePort(),
   try
      {ok, _} = eWSrv:openSrv(Name, Port, [
         {wsMod, wsHttpFixTestHandler},
         {tcpOpts, [{ip, {127, 0, 0, 1}}]}
      ]),
      Fun(Port)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

freePort() ->
   {ok, S} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
   {ok, {_, Port}} = inet:sockname(S),
   ok = gen_tcp:close(S),
   Port.

recvAll(Sock, Acc, Timeout) ->
   case gen_tcp:recv(Sock, 0, Timeout) of
      {ok, Bin} -> recvAll(Sock, <<Acc/binary, Bin/binary>>, Timeout);
      {error, closed} -> {ok, Acc};
      {error, timeout} when Acc =/= <<>> -> {ok, Acc};
      {error, Reason} -> {error, Reason}
   end.

takeResponse(Bin) ->
   case binary:match(Bin, <<"\r\n\r\n">>) of
      {Pos, 4} ->
         <<Head:Pos/binary, "\r\n\r\n", Rest0/binary>> = Bin,
         Lines = binary:split(Head, <<"\r\n">>, [global]),
         [StatusLine | HeaderLines] = Lines,
         [_, StatusBin | _] = binary:split(StatusLine, <<" ">>, [global]),
         Status = binary_to_integer(StatusBin),
         Headers = [parseHeader(L) || L <- HeaderLines, L =/= <<>>],
         {_, LenBin} = lists:keyfind(<<"Content-Length">>, 1, Headers),
         Len = binary_to_integer(LenBin),
         <<Body:Len/binary, Rest/binary>> = Rest0,
         {Status, Headers, Body, Rest}
   end.

parseHeader(Line) ->
   {Pos, 1} = binary:match(Line, <<":">>),
   <<Name:Pos/binary, ":", Value0/binary>> = Line,
   {Name, trim(Value0)}.

trim(<<$\s, Rest/binary>>) -> trim(Rest);
trim(Bin) -> Bin.
