-module(wsHttpFixTests).

-include_lib("eunit/include/eunit.hrl").
-include("wsCom.hrl").

%% logger primary filter 回调，用于断言 sendResponse 的日志级别（见 peerGoneResponseLogsWarning/0）
-export([logFilter/2]).

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

unsupported_expectation_returns_417_test_() ->
   {timeout, 10, fun unsupportedExpectation417/0}.

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

unsupportedExpectation417() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"POST /echo HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\n">>,
         <<"Content-Length: 5\r\n">>,
         <<"Expect: fancy-feature\r\n">>,
         <<"\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      ?assertMatch(<<"HTTP/1.1 417", _/binary>>, Bin),
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

chunk_response_owns_transfer_encoding_test_() ->
   {timeout, 10, fun chunkResponseOwnsTransferEncoding/0}.

chunkResponseOwnsTransferEncoding() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /chunk-te HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\nConnection: close\r\n\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      Lower = wsUtil:toLowerStr(Bin),
      ?assertNotEqual(nomatch, binary:match(Lower, <<"transfer-encoding: chunked">>)),
      ?assertEqual(nomatch, binary:match(Lower, <<"transfer-encoding: gzip">>)),
      ?assertNotEqual(nomatch, binary:match(Bin, <<"1\r\nx\r\n0\r\n\r\n">>)),
      gen_tcp:close(Sock)
   end).

chunk_response_accepts_non_empty_initial_test_() ->
   {timeout, 10, fun chunkResponseNonEmptyInitial/0}.

%% {chunk, Headers, Initial} 里的非空 Initial 必须原样分块落线。
%% 早先用 orelse 连接 sendChunk/2 的 ok | {error, _} 返回值，非空 Initial
%% 会直接抛 badarg，所以这个夹具必须有测试盯着。
chunkResponseNonEmptyInitial() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /chunk-initial HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\nConnection: close\r\n\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      Lower = wsUtil:toLowerStr(Bin),
      ?assertNotEqual(nomatch, binary:match(Bin, <<"HTTP/1.1 200 OK\r\n">>)),
      ?assertNotEqual(nomatch, binary:match(Lower, <<"transfer-encoding: chunked">>)),
      ?assertNotEqual(nomatch, binary:match(Bin, <<"5\r\nhello\r\n0\r\n\r\n">>)),
      %% chunk framing由框架生成，响应头里不能再声明 Content-Length。
      ?assertEqual(nomatch, binary:match(Lower, <<"content-length">>)),
      gen_tcp:close(Sock)
   end).

malformed_response_headers_are_not_serialized_test_() ->
   {timeout, 10, fun malformedResponseHeaders/0}.

malformedResponseHeaders() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /unsafe-headers HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\nConnection: close\r\n\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      ?assertNotEqual(nomatch, binary:match(Bin, <<"X-Good: ok">>)),
      ?assertEqual(nomatch, binary:match(Bin, <<"X-Injected">>)),
      {200, _Headers, <<"safe">>, <<>>} = takeResponse(Bin),
      gen_tcp:close(Sock)
   end).

informational_handler_status_becomes_500_test_() ->
   {timeout, 10, fun informationalHandlerStatus/0}.

informationalHandlerStatus() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /informational-final HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\nConnection: close\r\n\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      {500, _Headers, <<"Internal server error">>, <<>>} = takeResponse(Bin),
      ?assertEqual(nomatch, binary:match(Bin, <<"103 Early Hints">>)),
      gen_tcp:close(Sock)
   end).

invalid_handler_status_becomes_500_test_() ->
   {timeout, 10, fun invalidHandlerStatus/0}.

%% 这条用例必然会让服务器打出一条 ERROR 级 "handle return error WsReq:..." 日志——
%% 那是被测行为本身，不是失败信号。判绿看断言：状态码是 500，且响应里没有 X-Injected。
invalidHandlerStatus() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /bad-status HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\nConnection: close\r\n\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      {500, _Headers, _Body, <<>>} = takeResponse(Bin),
      ?assertEqual(nomatch, binary:match(Bin, <<"X-Injected">>)),
      gen_tcp:close(Sock)
   end).

handler_init_runs_without_custom_supervisor_test_() ->
   {timeout, 10, fun handlerInitWithoutSupervisor/0}.

handlerInitWithoutSupervisor() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /init-state HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\n">>,
         <<"Connection: close\r\n">>,
         <<"\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      {200, _Headers, <<"initialized">>, <<>>} = takeResponse(Bin),
      gen_tcp:close(Sock)
   end).

lowercase_response_headers_are_normalized_semantically_test_() ->
   {timeout, 10, fun lowercaseResponseHeaders/0}.

lowercaseResponseHeaders() ->
   withServer(fun(Port) ->
      {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port,
         [binary, {packet, raw}, {active, false}], 2000),
      ok = gen_tcp:send(Sock, [
         <<"GET /lowercase-headers HTTP/1.1\r\n">>,
         <<"Host: 127.0.0.1\r\n">>,
         <<"Connection: keep-alive\r\n">>,
         <<"\r\n">>
      ]),
      {ok, Bin} = recvAll(Sock, <<>>, 3000),
      {200, Headers, <<"abc">>, <<>>} = takeResponse(Bin),
      LengthHeaders = [
         V || {Name, V} <- Headers,
              wsUtil:toLowerStr(Name) =:= <<"content-length">>
      ],
      ConnectionHeaders = [
         V || {Name, V} <- Headers,
              wsUtil:toLowerStr(Name) =:= <<"connection">>
      ],
      ?assertEqual([<<"3">>], LengthHeaders),
      ?assertEqual([<<"close">>], [wsUtil:toLowerStr(V) || V <- ConnectionHeaders]),
      gen_tcp:close(Sock)
   end).

%% ============================================================================
%% Helpers
%% ============================================================================

%% ============================================================================
%% Unit: sendResponse 对「对端已断开」只记 warning
%% ============================================================================
%% 关闭后的 socket 交给 ntCom:syncSend，内部 port_command/3 会 badarg 并被 eNet
%% 统一兜成 {error, einval}（实测 LISTEN / ACCEPTED 两种死 port 都是这个值）；
%% ssl 侧对应 closed / econnreset / epipe。这类「对端先走了」在压测(wrk)收尾、
%% 浏览器提前导航时必然发生，必须落 warning——否则真实服务上会被 ERROR REPORT 刷屏，
%% 把真正的写失败淹掉。
%% 注意：这条用例自己必然会打出一条 WARNING REPORT（那正是被测行为），判绿看断言。
peer_gone_response_logs_warning_test_() ->
   {timeout, 10, fun peerGoneResponseLogsWarning/0}.

peerGoneResponseLogsWarning() ->
   installLogCapture(),
   try
      {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
      {ok, Port} = inet:port(Listen),
      {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
      {ok, Server} = gen_tcp:accept(Listen),
      ok = gen_tcp:close(Server),
      _ = drainLogs(),
      ?assertEqual({error, einval}, wsHttp:sendResponse(Server, 'GET', 200, [], <<"bye">>)),
      %% 只应有一条日志，且是 warning：没有 ERROR REPORT
      [{Level, Text}] = drainLogs(),
      ?assertEqual(warning, Level),
      ?assertNotEqual(nomatch, binary:match(Text, <<"peer gone">>)),
      ok = gen_tcp:close(Client),
      ok = gen_tcp:close(Listen)
   after
      removeLogCapture()
   end.

%% primary filter 在「发起日志的进程」内同步执行，所以投递后测试进程的邮箱里
%% 立刻就能收到——不需要等异步 handler 落地。事件原样放行，不打乱默认输出。
installLogCapture() ->
   _ = logger:remove_primary_filter(wshxLogCap),
   register(wshxLogRecv, self()),
   ok = logger:add_primary_filter(wshxLogCap, {fun ?MODULE:logFilter/2, #{}}).

removeLogCapture() ->
   _ = logger:remove_primary_filter(wshxLogCap),
   try unregister(wshxLogRecv) catch _:_ -> ok end,
   ok.

logFilter(#{level := Level, msg := Msg} = Event, _Extra) ->
   case whereis(wshxLogRecv) of
      undefined ->
         Event;
      Pid ->
         Pid ! {wshxLog, Level, fmtLogMsg(Msg)},
         Event
   end.

fmtLogMsg({string, S}) ->
   unicode:characters_to_binary(S);
fmtLogMsg({report, R}) ->
   unicode:characters_to_binary(io_lib:format("~0p", [R]));
fmtLogMsg({Fmt, Args}) ->
   unicode:characters_to_binary(io_lib:format(unicode:characters_to_list(Fmt), Args));
fmtLogMsg(Other) ->
   unicode:characters_to_binary(io_lib:format("~0p", [Other])).

drainLogs() ->
   drainLogs([]).

drainLogs(Acc) ->
   receive
      {wshxLog, Level, Text} -> drainLogs([{Level, Text} | Acc])
   after 0 ->
      lists:reverse(Acc)
   end.

%% ============================================================================
%% Unit: 未实现的可选回调不该被当成错误
%% ============================================================================
%% wsHer 把 handleCall/handleCast/handleInfo 声明为 optional，默认 handler wsTPHer
%% 三个都没实现。引擎曾经无条件调用 -> undef -> 每条都刷 ERROR REPORT。
%% 触发场景就是「大响应吞吐」：/h2/bytes/N 的 producer 是 spawn_link 出去的，
%% 正常退出会给连接进程发 {'EXIT',Pid,normal}；keep-alive 或 HTTP/2 长连接下
%% 连接进程回到 loop 时会消费这条消息并交给 handleInfo。
default_handler_ignores_info_without_error_test_() ->
   {timeout, 20, fun defaultHandlerIgnoresInfoWithoutError/0}.

%% 默认 handler 收到 {'EXIT', Pid, normal} 这类 info 消息时必须安静地忽略。
%% 引擎侧不再做 function_exported 守卫（见 wsHer:optional_callbacks 的说明），
%% 由 handler 提供默认实现来兜住——漏实现会直接 undef，所以这里盯的是 wsTPHer 的完整性。
defaultHandlerIgnoresInfoWithoutError() ->
   installLogCapture(),
   try
      withDefaultHandlerServer(fun(Port) ->
         {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
         %% 故意不发 Connection: close —— 长连接才会去消费那条 EXIT 消息
         ok = gen_tcp:send(Sock, <<"GET /h2/bytes/20000 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n">>),
         {ok, Bin} = recvAll(Sock, <<>>, 1500),
         ?assertMatch({0, _}, binary:match(Bin, <<"HTTP/1.1 200 OK">>)),
         ?assertNotEqual(nomatch, binary:match(Bin, <<"0\r\n\r\n">>)),
         timer:sleep(300),
         ok = gen_tcp:close(Sock)
      end),
      ?assertEqual([], [{Level, Text} || {Level, Text} <- drainLogs(), Level =:= error])
   after
      removeLogCapture()
   end.

%% 用默认 handler（wsTPHer）起服务：验证它作为 behaviour 的默认实现能安静吃下 info 消息。
withDefaultHandlerServer(Fun) ->
   {ok, _} = application:ensure_all_started(eWSrv),
   Name = list_to_atom("ws_default_" ++ integer_to_list(erlang:unique_integer([positive]))),
   Port = freePort(),
   try
      {ok, _} = eWSrv:openSrv(Name, Port, [
         {wsMod, wsTPHer},
         {tcpOpts, [{ip, {127, 0, 0, 1}}]}
      ]),
      Fun(Port)
   after
      try eWSrv:closeSrv(Name) catch _:_ -> ok end
   end.

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
      try eWSrv:closeSrv(Name) catch _:_ -> ok end
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
