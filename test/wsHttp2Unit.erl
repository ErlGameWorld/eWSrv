-module(wsHttp2Unit).

-include_lib("eunit/include/eunit.hrl").

-define(PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(END_STREAM, 16#01).
-define(END_HEADERS, 16#04).


settings_last_duplicate_value_wins_test() ->
   %% SETTINGS_INITIAL_WINDOW_SIZE(4) appears twice; RFC 9113 says last wins.
   Payload = <<4:16, 1000:32, 4:16, 2000:32>>,
   {ok, Settings} = wsHttp2Frame:settingsDecode(Payload),
   ?assertEqual(2000, proplists:get_value(initial_window_size, Settings)),
   ?assertEqual(1, length([V || {initial_window_size, V} <- Settings])).

hpack_roundtrip_test() ->
   Headers = [
      {<<":method">>, <<"GET">>},
      {<<":scheme">>, <<"https">>},
      {<<":authority">>, <<"example.com">>},
      {<<":path">>, <<"/hello">>},
      {<<"user-agent">>, <<"eWSrv-test">>}
   ],
   {Encoded, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
   {ok, Decoded, _Rx} = wsHpack:decode(iolist_to_binary(Encoded), wsHpack:new()),
   ?assertEqual(Headers, Decoded).

hpack_lowercase_fast_path_roundtrip_test() ->
   Headers = [
      {<<":status">>, <<"200">>},
      {<<"content-type">>, <<"text/plain">>},
      {<<"cache-control">>, <<"no-store">>}
   ],
   {Encoded, _Tx} = wsHpack:encodeLower(Headers, wsHpack:new()),
   {ok, Decoded, _Rx} = wsHpack:decode(iolist_to_binary(Encoded), wsHpack:new()),
   ?assertEqual(Headers, Decoded).

huffman_roundtrip_test() ->
   Bin = <<"www.example.com: gzip, deflate; hello HTTP/2">>,
   Encoded = wsHuffman:encode(Bin),
   ?assertEqual(Bin, wsHuffman:decode(Encoded)).

frame_split_roundtrip_test() ->
   Payload = binary:copy(<<"a">>, 40000),
   Frames = wsHttp2Frame:dataFrames(Payload, 1, 16384),
   {_Parser, Parsed} = wsHttp2Frame:feed(wsHttp2Frame:new(), iolist_to_binary(Frames)),
   Data = iolist_to_binary([P || {frame, data, _Flags, 1, P} <- Parsed]),
   ?assertEqual(Payload, Data),
   {frame, data, LastFlags, 1, _} = lists:last(Parsed),
   ?assert(LastFlags band ?END_STREAM =/= 0).

frame_accepts_nested_iodata_without_semantic_change_test() ->
   Wire = wsHttp2Frame:frame(data, 3, [<<"ab">>, [<<"cd">>, "ef"]], 0),
   {_Parser, [{frame, data, 0, 3, Payload}]} =
      wsHttp2Frame:feed(wsHttp2Frame:new(), iolist_to_binary(Wire)),
   ?assertEqual(<<"abcdef">>, Payload).

http2_prior_knowledge_integration_test_() ->
   {timeout, 20, fun priorKnowledge/0}.

priorKnowledge() ->
   {ok, _} = application:ensure_all_started(eWSrv),
   Name = ws_http2_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {ok, _} = eWSrv:openSrv(Name, 0, [{http2, true}, {wsMod, wsTPHer}, {chunkedSupp, true}]),
      ListenerName = ntCom:lsName(tcp, Name),
      Port = ntTcpListener:getListenPort(ListenerName),
      {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {packet, raw}, {active, false}, {nodelay, true}], 5000),

      %% Client connection preface MUST be followed by SETTINGS.
      ok = gen_tcp:send(Sock, [?PREFACE, wsHttp2Frame:settingsFrame([])]),
      {Parser1, ServerFrames} = recvUntil(fun hasSettings/1, Sock, wsHttp2Frame:new(), [], 5000),
      ?assert(lists:any(fun
         ({frame, settings, Flags, 0, _}) -> Flags band 1 =:= 0;
         (_) -> false
      end, ServerFrames)),

      RequestHeaders = [
         {<<":method">>, <<"GET">>},
         {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>},
         {<<":path">>, <<"/hello">>}
      ],
      {Block, _Tx} = wsHpack:encode(RequestHeaders, wsHpack:new()),
      RequestFrame = wsHttp2Frame:headersFrames(Block, 1, 16384, true),
      %% ACK server SETTINGS, then open stream 1.
      ok = gen_tcp:send(Sock, [wsHttp2Frame:ackFrame(), RequestFrame]),

      {_Parser2, RespFrames} = recvUntil(fun responseEnded/1, Sock, Parser1, [], 5000),
      {RespHeaders, RespBody} = decodeResponse(RespFrames),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, RespHeaders)),
      ?assertEqual(<<"Hello, World!">>, RespBody),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_tls_alpn_integration_test_() ->
   {timeout, 20, fun tlsAlpn/0}.

tlsAlpn() ->
   {ok, _} = application:ensure_all_started(eWSrv),
   Name = ws_http2_tls_eunit,
   _ = catch eWSrv:closeSrv(Name),
   Priv = code:priv_dir(eWSrv),
   Cert = filename:join(Priv, "server_cert.pem"),
   Key = filename:join(Priv, "server_key.pem"),
   try
      {ok, _} = eWSrv:openSrv(Name, 0, [
         {http2, true},
         {wsMod, wsTPHer},
         {sslOpts, [{certfile, Cert}, {keyfile, Key}, {verify, verify_none}]}
      ]),
      ListenerName = ntCom:lsName(ssl, Name),
      Port = ntSslListener:getListenPort(ListenerName),
      {ok, Sock} = ssl:connect("127.0.0.1", Port, [
         binary,
         {active, false},
         {verify, verify_none},
         {alpn_advertised_protocols, [<<"h2">>]}
      ], 5000),
      ?assertEqual({ok, <<"h2">>}, ssl:negotiated_protocol(Sock)),

      ok = ssl:send(Sock, [?PREFACE, wsHttp2Frame:settingsFrame([])]),
      {Parser1, ServerFrames} = recvUntilSsl(fun hasSettings/1, Sock, wsHttp2Frame:new(), [], 5000),
      ?assert(hasSettings(ServerFrames)),

      RequestHeaders = [
         {<<":method">>, <<"GET">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"127.0.0.1">>},
         {<<":path">>, <<"/hello">>}
      ],
      {Block, _Tx} = wsHpack:encode(RequestHeaders, wsHpack:new()),
      ok = ssl:send(Sock, [wsHttp2Frame:ackFrame(), wsHttp2Frame:headersFrames(Block, 1, 16384, true)]),
      {_Parser2, RespFrames} = recvUntilSsl(fun responseEnded/1, Sock, Parser1, [], 5000),
      {RespHeaders, RespBody} = decodeResponse(RespFrames),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, RespHeaders)),
      ?assertEqual(<<"Hello, World!">>, RespBody),
      ssl:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

recvUntilSsl(Pred, Sock, Parser0, Acc0, Timeout) ->
   case Pred(Acc0) of
      true -> {Parser0, Acc0};
      false ->
         {ok, Bin} = ssl:recv(Sock, 0, Timeout),
         {Parser, Frames} = wsHttp2Frame:feed(Parser0, Bin),
         Acc = Acc0 ++ Frames,
         recvUntilSsl(Pred, Sock, Parser, Acc, Timeout)
   end.

http2_header_compatibility_test_() ->
   {timeout, 20, fun headerCompatibility/0}.

headerCompatibility() ->
   Name = ws_http2_header_compat_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsTPHer),
      Origin = <<"https://example.com">>,
      Headers = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/api/test">>},
         {<<"origin">>, Origin}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, true)),
      {_Parser2, Frames} = recvUntil(fun responseEnded/1, Sock, Parser1, [], 5000),
      {RespHeaders, _Body} = decodeResponse(Frames),
      ?assertEqual(Origin, proplists:get_value(<<"access-control-allow-origin">>, RespHeaders)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_continuation_integration_test_() ->
   {timeout, 20, fun continuationRequest/0}.

continuationRequest() ->
   Name = ws_http2_cont_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      Large = base64:encode(crypto:strong_rand_bytes(18000)),
      Headers = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/one">>},
         {<<"x-large">>, Large}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      ReqFrames = wsHttp2Frame:headersFrames(Block, 1, 16384, true),
      {_P, ParsedReqFrames} = wsHttp2Frame:feed(wsHttp2Frame:new(), iolist_to_binary(ReqFrames)),
      ?assert(lists:any(fun
         ({frame, continuation, _Flags, 1, _}) -> true;
         (_) -> false
      end, ParsedReqFrames)),
      ok = gen_tcp:send(Sock, ReqFrames),
      {_Parser2, Frames} = recvUntil(fun responseEnded/1, Sock, Parser1, [], 5000),
      {RespHeaders, Body} = decodeResponse(Frames),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, RespHeaders)),
      ?assertEqual(<<"one">>, Body),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_authority_is_exposed_as_host_test_() ->
   {timeout, 20, fun authorityAsHost/0}.

authorityAsHost() ->
   Name = ws_http2_host_compat_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsTPHer),
      Headers = [
         {<<":method">>, <<"GET">>},
         {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"example.test:8080">>},
         {<<":path">>, <<"/headers">>}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, true)),
      {_Parser2, Frames} = recvUntil(fun responseEnded/1, Sock, Parser1, [], 5000),
      {_RespHeaders, Body} = decodeResponse(Frames),
      ?assertNotEqual(nomatch, binary:match(Body, <<"Host: example.test:8080">>)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_invalid_method_is_stream_error_test_() ->
   {timeout, 20, fun invalidMethod/0}.

invalidMethod() ->
   Name = ws_http2_bad_method_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      Headers = [
         {<<":method">>, <<"BAD METHOD">>},
         {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>},
         {<<":path">>, <<"/one">>}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, true)),
      IsRst = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _Flags, 1, Payload}) ->
            wsHttp2Frame:rstStreamCode(Payload) =:= {ok, protocol_error};
         (_) -> false
      end, Fs) end,
      {Parser2, Frames1} = recvUntil(IsRst, Sock, Parser1, [], 5000),
      ?assert(IsRst(Frames1)),

      %% The connection remains usable after the stream-local error.
      H3 = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/two">>}
      ],
      {B3, _} = wsHpack:encode(H3, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B3, 3, 16384, true)),
      {_Parser3, Frames2} = recvUntil(fun(Fs) -> streamEnded(3, Fs) end,
         Sock, Parser2, Frames1, 5000),
      {HMap, BMap} = decodeResponses(Frames2),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, maps:get(3, HMap))),
      ?assertEqual(<<"two">>, maps:get(3, BMap)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_closed_stream_data_keeps_connection_alive_test_() ->
   {timeout, 20, fun closedStreamData/0}.

closedStreamData() ->
   Name = ws_http2_closed_data_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      H1 = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/one">>}
      ],
      {B1, Tx1} = wsHpack:encode(H1, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B1, 1, 16384, true)),
      {Parser2, Frames1} = recvUntil(fun(Fs) -> streamEnded(1, Fs) end,
         Sock, Parser1, [], 5000),

      %% Late DATA on a closed stream must consume/replenish connection credit,
      %% cause a stream-local STREAM_CLOSED, and not kill the H2 connection.
      ok = gen_tcp:send(Sock, wsHttp2Frame:frame(data, 1, <<"late">>, ?END_STREAM)),
      IsClosedRst = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _Flags, 1, Payload}) ->
            wsHttp2Frame:rstStreamCode(Payload) =:= {ok, stream_closed};
         (_) -> false
      end, Fs) end,
      {Parser3, Frames2} = recvUntil(IsClosedRst, Sock, Parser2, Frames1, 5000),
      ?assert(IsClosedRst(Frames2)),
      %% 小额 late DATA 会累计半窗再发 WINDOW_UPDATE，这里不要求立刻看到 WU。

      H3 = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/two">>}
      ],
      {B3, _Tx2} = wsHpack:encode(H3, Tx1),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B3, 3, 16384, true)),
      {_Parser4, Frames3} = recvUntil(fun(Fs) -> streamEnded(3, Fs) end,
         Sock, Parser3, Frames2, 5000),
      {HMap, BMap} = decodeResponses(Frames3),
      ?assertEqual(<<"two">>, maps:get(3, BMap)),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, maps:get(3, HMap))),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_informational_final_is_rejected_test_() ->
   {timeout, 20, fun informationalFinalRejected/0}.

informationalFinalRejected() ->
   Name = ws_http2_info_final_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      H = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/informational-final">>}
      ],
      {B, _Tx} = wsHpack:encode(H, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B, 1, 16384, true)),
      {_Parser2, Frames} = recvUntil(fun responseEnded/1, Sock, Parser1, [], 5000),
      {RespHeaders, Body} = decodeResponse(Frames),
      ?assertEqual(<<"500">>, proplists:get_value(<<":status">>, RespHeaders)),
      ?assertEqual(<<"Internal server error">>, Body),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_205_has_no_content_test_() ->
   {timeout, 20, fun noContent205/0}.

noContent205() ->
   Name = ws_http2_205_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      H = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/reset-content">>}
      ],
      {B, _Tx} = wsHpack:encode(H, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B, 1, 16384, true)),
      {_Parser2, Frames} = recvUntil(fun responseEnded/1, Sock, Parser1, [], 5000),
      {RespHeaders, Body} = decodeResponse(Frames),
      ?assertEqual(<<"205">>, proplists:get_value(<<":status">>, RespHeaders)),
      ?assertEqual(<<"0">>, proplists:get_value(<<"content-length">>, RespHeaders)),
      ?assertEqual(<<>>, Body),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_post_data_integration_test_() ->
   {timeout, 20, fun postData/0}.

postData() ->
   Name = ws_http2_post_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      Headers = [
         {<<":method">>, <<"POST">>},
         {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>},
         {<<":path">>, <<"/echo">>},
         {<<"content-length">>, <<"11">>}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      ok = gen_tcp:send(Sock, [
         wsHttp2Frame:headersFrames(Block, 1, 16384, false),
         wsHttp2Frame:frame(data, 1, <<"hello ">>, 0),
         wsHttp2Frame:frame(data, 1, <<"world">>, ?END_STREAM)
      ]),
      {_Parser2, Frames} = recvUntil(fun responseEnded/1, Sock, Parser1, [], 5000),
      {RespHeaders, Body} = decodeResponse(Frames),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, RespHeaders)),
      ?assertEqual(<<"hello world">>, Body),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_multiplex_integration_test_() ->
   {timeout, 20, fun multiplex/0}.

multiplex() ->
   Name = ws_http2_multi_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      Base1 = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/one">>}
      ],
      {Block1, Tx1} = wsHpack:encode(Base1, wsHpack:new()),
      Base3 = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/two">>}
      ],
      {Block3, _Tx2} = wsHpack:encode(Base3, Tx1),
      ok = gen_tcp:send(Sock, [
         wsHttp2Frame:headersFrames(Block1, 1, 16384, true),
         wsHttp2Frame:headersFrames(Block3, 3, 16384, true)
      ]),
      Pred = fun(Fs) -> streamEnded(1, Fs) andalso streamEnded(3, Fs) end,
      {_Parser2, Frames} = recvUntil(Pred, Sock, Parser1, [], 5000),
      {HMap, BMap} = decodeResponses(Frames),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, maps:get(1, HMap))),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, maps:get(3, HMap))),
      ?assertEqual(<<"one">>, maps:get(1, BMap)),
      ?assertEqual(<<"two">>, maps:get(3, BMap)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_request_body_timeout_test_() ->
   {timeout, 20, fun requestBodyTimeout/0}.

requestBodyTimeout() ->
   {ok, _} = application:ensure_all_started(eWSrv),
   Name = ws_http2_req_timeout_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {ok, _} = eWSrv:openSrv(Name, 0, [
         {http2, true}, {wsMod, wsHttp2TestHandler},
         {requestTimeout, 100}, {keepAliveTimeout, 5000}
      ]),
      ListenerName = ntCom:lsName(tcp, Name),
      Port = ntTcpListener:getListenPort(ListenerName),
      {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {packet, raw}, {active, false}], 5000),
      ok = gen_tcp:send(Sock, [?PREFACE, wsHttp2Frame:settingsFrame([])]),
      {Parser1, _} = recvUntil(fun hasSettings/1, Sock, wsHttp2Frame:new(), [], 5000),
      ok = gen_tcp:send(Sock, wsHttp2Frame:ackFrame()),
      Headers = [
         {<<":method">>, <<"POST">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/echo">>},
         {<<"content-length">>, <<"10">>}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      %% Do not END_STREAM and do not send DATA: the stream must time out independently.
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, false)),
      Pred = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _Flags, 1, _Payload}) -> true;
         (_) -> false
      end, Fs) end,
      {_Parser2, Frames} = recvUntil(Pred, Sock, Parser1, [], 2000),
      ?assert(Pred(Frames)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_idle_goaway_test_() ->
   {timeout, 20, fun idleGoaway/0}.

idleGoaway() ->
   {ok, _} = application:ensure_all_started(eWSrv),
   Name = ws_http2_idle_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {ok, _} = eWSrv:openSrv(Name, 0, [{http2, true}, {wsMod, wsHttp2TestHandler}, {keepAliveTimeout, 100}]),
      ListenerName = ntCom:lsName(tcp, Name),
      Port = ntTcpListener:getListenPort(ListenerName),
      {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {packet, raw}, {active, false}], 5000),
      ok = gen_tcp:send(Sock, [?PREFACE, wsHttp2Frame:settingsFrame([])]),
      {Parser1, _} = recvUntil(fun hasSettings/1, Sock, wsHttp2Frame:new(), [], 5000),
      ok = gen_tcp:send(Sock, wsHttp2Frame:ackFrame()),
      Pred = fun(Fs) -> lists:any(fun
         ({frame, goaway, _Flags, 0, _Payload}) -> true;
         (_) -> false
      end, Fs) end,
      {_Parser2, Frames} = recvUntil(Pred, Sock, Parser1, [], 2000),
      ?assert(Pred(Frames)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_compression_integration_test_() ->
   {timeout, 20, fun compression/0}.

compression() ->
   Name = ws_http2_compress_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsTPHer),
      Headers = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/compressed">>},
         {<<"accept-encoding">>, <<"gzip;q=1, deflate;q=0.5">>}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, true)),
      {_Parser2, Frames} = recvUntil(fun responseEnded/1, Sock, Parser1, [], 5000),
      {RespHeaders, EncodedBody} = decodeResponse(Frames),
      ?assertEqual(<<"gzip">>, proplists:get_value(<<"content-encoding">>, RespHeaders)),
      ?assertEqual(<<"Accept-Encoding">>, proplists:get_value(<<"vary">>, RespHeaders)),
      Body = zlib:gunzip(EncodedBody),
      ?assertEqual(binary:copy(<<"Hello World!">>, 86), Body),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_slow_stream_does_not_block_fast_stream_test_() ->
   {timeout, 20, fun slowDoesNotBlockFast/0}.

slowDoesNotBlockFast() ->
   Name = ws_http2_parallel_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      SlowHeaders = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/slow">>}
      ],
      {SlowBlock, Tx1} = wsHpack:encode(SlowHeaders, wsHpack:new()),
      FastHeaders = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/two">>}
      ],
      {FastBlock, _Tx2} = wsHpack:encode(FastHeaders, Tx1),
      ok = gen_tcp:send(Sock, [
         wsHttp2Frame:headersFrames(SlowBlock, 1, 16384, true),
         wsHttp2Frame:headersFrames(FastBlock, 3, 16384, true)
      ]),
      {Parser2, Frames1} = recvUntil(
         fun(Fs) -> streamEnded(3, Fs) end, Sock, Parser1, [], 300),
      ?assert(streamEnded(3, Frames1)),
      ?assertNot(streamEnded(1, Frames1)),
      {_Parser3, Frames2} = recvUntil(
         fun(Fs) -> streamEnded(1, Fs) end, Sock, Parser2, Frames1, 2000),
      {HMap, BMap} = decodeResponses(Frames2),
      ?assertEqual(<<"two">>, maps:get(3, BMap)),
      ?assertEqual(<<"slow">>, maps:get(1, BMap)),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, maps:get(1, HMap))),
      ?assertEqual(<<"200">>, proplists:get_value(<<":status">>, maps:get(3, HMap))),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_send_flow_control_integration_test_() ->
   {timeout, 20, fun sendFlowControl/0}.

sendFlowControl() ->
   Name = ws_http2_flow_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      Headers = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/large">>}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, true)),
      PredWindowFull = fun(Fs) -> streamDataSize(1, Fs) >= 65535 end,
      {Parser2, Frames1} = recvUntil(PredWindowFull, Sock, Parser1, [], 5000),
      ?assertEqual(65535, streamDataSize(1, Frames1)),
      ?assertNot(streamEnded(1, Frames1)),

      %% Both connection and stream windows are exhausted and must be reopened.
      ok = gen_tcp:send(Sock, [wsHttp2Frame:windowUpdateFrame(0, 50000), wsHttp2Frame:windowUpdateFrame(1, 50000)]),
      {Parser3, Frames2} = recvUntil(fun(Fs) -> streamEnded(1, Fs) end, Sock, Parser2, Frames1, 5000),
      _ = Parser3,
      ?assertEqual(100000, streamDataSize(1, Frames2)),
      {_Headers, Body} = decodeResponse(Frames2),
      ?assertEqual(binary:copy(<<"x">>, 100000), Body),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

openPriorKnowledge(Name, Handler) ->
   {ok, _} = application:ensure_all_started(eWSrv),
   {ok, _} = eWSrv:openSrv(Name, 0, [{http2, true}, {wsMod, Handler}]),
   ListenerName = ntCom:lsName(tcp, Name),
   Port = ntTcpListener:getListenPort(ListenerName),
   {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {packet, raw}, {active, false}, {nodelay, true}], 5000),
   ok = gen_tcp:send(Sock, [?PREFACE, wsHttp2Frame:settingsFrame([])]),
   {Parser1, _ServerFrames} = recvUntil(fun hasSettings/1, Sock, wsHttp2Frame:new(), [], 5000),
   ok = gen_tcp:send(Sock, wsHttp2Frame:ackFrame()),
   {Sock, Parser1}.

streamEnded(StreamId, Frames) ->
   lists:any(fun
      ({frame, data, Flags, Id, _}) when Id =:= StreamId -> Flags band ?END_STREAM =/= 0;
      ({frame, headers, Flags, Id, _}) when Id =:= StreamId -> Flags band ?END_STREAM =/= 0;
      (_) -> false
   end, Frames).

streamDataSize(StreamId, Frames) ->
   lists:sum([byte_size(P) || {frame, data, _Flags, Id, P} <- Frames, Id =:= StreamId]).

hasSettings(Frames) ->
   lists:any(fun
      ({frame, settings, Flags, 0, _}) -> Flags band 1 =:= 0;
      (_) -> false
   end, Frames).

responseEnded(Frames) ->
   lists:any(fun
      ({frame, data, Flags, 1, _}) -> Flags band ?END_STREAM =/= 0;
      ({frame, headers, Flags, 1, _}) -> Flags band ?END_STREAM =/= 0;
      (_) -> false
   end, Frames).

recvUntil(Pred, Sock, Parser0, Acc0, Timeout) ->
   case Pred(Acc0) of
      true -> {Parser0, Acc0};
      false ->
         {ok, Bin} = gen_tcp:recv(Sock, 0, Timeout),
         {Parser, Frames} = wsHttp2Frame:feed(Parser0, Bin),
         Acc = Acc0 ++ Frames,
         recvUntil(Pred, Sock, Parser, Acc, Timeout)
   end.

decodeResponse(Frames) ->
   decodeStreamResponse(1, Frames).

decodeStreamResponse(StreamId, Frames) ->
   {HeaderBlock, _} = collectHeaderBlock(StreamId, Frames, none, []),
   {ok, Headers, _Rx} = wsHpack:decode(HeaderBlock, wsHpack:new()),
   Body = iolist_to_binary([P || {frame, data, _Flags, Id, P} <- Frames, Id =:= StreamId]),
   {Headers, Body}.

collectHeaderBlock(_StreamId, [], _Pending, Acc) ->
   {iolist_to_binary(lists:reverse(Acc)), []};
collectHeaderBlock(StreamId, [{frame, headers, Flags, StreamId, Payload} | Rest], none, _Acc) ->
   case Flags band ?END_HEADERS =/= 0 of
      true -> {Payload, Rest};
      false -> collectHeaderBlock(StreamId, Rest, pending, [Payload])
   end;
collectHeaderBlock(StreamId, [{frame, continuation, Flags, StreamId, Payload} | Rest], pending, Acc) ->
   case Flags band ?END_HEADERS =/= 0 of
      true -> {iolist_to_binary(lists:reverse([Payload | Acc])), Rest};
      false -> collectHeaderBlock(StreamId, Rest, pending, [Payload | Acc])
   end;
collectHeaderBlock(StreamId, [_ | Rest], Pending, Acc) ->
   collectHeaderBlock(StreamId, Rest, Pending, Acc).

decodeResponses(Frames) ->
   decodeResponses(Frames, wsHpack:new(), #{}, #{}, none).

decodeResponses([], _Ctx, HMap, BMap, none) ->
   {HMap, maps:map(fun(_K, Parts) -> iolist_to_binary(lists:reverse(Parts)) end, BMap)};
decodeResponses([{frame, headers, Flags, Id, Payload} | Rest], Ctx, HMap, BMap, none) ->
   case Flags band ?END_HEADERS =/= 0 of
      true ->
         {ok, Headers, Ctx1} = wsHpack:decode(Payload, Ctx),
         decodeResponses(Rest, Ctx1, HMap#{Id => Headers}, BMap, none);
      false ->
         decodeResponses(Rest, Ctx, HMap, BMap, {Id, [Payload]})
   end;
decodeResponses([{frame, continuation, Flags, Id, Payload} | Rest], Ctx, HMap, BMap, {Id, Acc}) ->
   case Flags band ?END_HEADERS =/= 0 of
      true ->
         Block = iolist_to_binary(lists:reverse([Payload | Acc])),
         {ok, Headers, Ctx1} = wsHpack:decode(Block, Ctx),
         decodeResponses(Rest, Ctx1, HMap#{Id => Headers}, BMap, none);
      false ->
         decodeResponses(Rest, Ctx, HMap, BMap, {Id, [Payload | Acc]})
   end;
decodeResponses([{frame, data, _Flags, Id, Payload} | Rest], Ctx, HMap, BMap, Pending) ->
   Parts = maps:get(Id, BMap, []),
   decodeResponses(Rest, Ctx, HMap, BMap#{Id => [Payload | Parts]}, Pending);
decodeResponses([_ | Rest], Ctx, HMap, BMap, Pending) ->
   decodeResponses(Rest, Ctx, HMap, BMap, Pending).

%% RFC 7541 Appendix C interoperability vectors.
huffman_rfc7541_vector_test() ->
   Encoded = wsHuffman:encode(<<"www.example.com">>),
   ?assertEqual(<<16#f1,16#e3,16#c2,16#e5,16#f2,16#3a,16#6b,16#a0,16#ab,16#90,16#f4,16#ff>>, Encoded),
   ?assertEqual(<<"www.example.com">>, wsHuffman:decode(Encoded)).

hpack_rfc7541_plain_request_vector_test() ->
   Block = <<16#82,16#86,16#84,16#41,16#0f,"www.example.com">>,
   {ok, Headers, _Ctx} = wsHpack:decode(Block, wsHpack:new()),
   ?assertEqual([
      {<<":method">>, <<"GET">>},
      {<<":scheme">>, <<"http">>},
      {<<":path">>, <<"/">>},
      {<<":authority">>, <<"www.example.com">>}
   ], Headers).

hpack_rfc7541_huffman_request_vector_test() ->
   Block = <<16#82,16#86,16#84,16#41,16#8c, 16#f1,16#e3,16#c2,16#e5,16#f2,16#3a,16#6b,16#a0,16#ab,16#90,16#f4,16#ff>>,
   {ok, Headers, _Ctx} = wsHpack:decode(Block, wsHpack:new()),
   ?assertEqual(<<"www.example.com">>, proplists:get_value(<<":authority">>, Headers)).

frame_parser_byte_by_byte_test() ->
   Wire = iolist_to_binary([
      wsHttp2Frame:settingsFrame([{initial_window_size, 70000}]),
      wsHttp2Frame:pingFrame(<<"12345678">>)
   ]),
   {_Parser, Frames} = feedByteByByte(Wire, wsHttp2Frame:new(), []),
   ?assertEqual(2, length(Frames)),
   ?assertMatch({frame, settings, 0, 0, _}, hd(Frames)),
   ?assertMatch({frame, ping, 0, 0, <<"12345678">>}, lists:nth(2, Frames)).

settings_bad_length_test() ->
   ?assertEqual({error, badSettingsLength}, wsHttp2Frame:settingsDecode(<<0,1,2>>)).

feedByteByByte(<<>>, Parser, Acc) ->
   {Parser, Acc};
feedByteByByte(<<Byte, Rest/binary>>, Parser0, Acc0) ->
   {Parser, Frames} = wsHttp2Frame:feed(Parser0, <<Byte>>),
   feedByteByByte(Rest, Parser, Acc0 ++ Frames).

%% ------------------------------------------------------------------
%% Additional low-level regressions retained from the original feature/http2
%% branch. These cover malformed HPACK inputs and pure frame helpers that are
%% cheaper and more precise than the higher-level integration tests.
%% ------------------------------------------------------------------

frame_helper_roundtrip_test() ->
   Io = [
      wsHttp2Frame:settingsFrame([{max_concurrent_streams, 100}]),
      wsHttp2Frame:pingFrame(<<"12345678">>),
      wsHttp2Frame:windowUpdateFrame(0, 1024)
   ],
   {_Parser, Frames} = wsHttp2Frame:feed(wsHttp2Frame:new(), iolist_to_binary(Io)),
   ?assertMatch([
      {frame, settings, 0, 0, _},
      {frame, ping, 0, 0, <<"12345678">>},
      {frame, window_update, 0, 0, _}
   ], Frames).

partial_frame_boundary_test() ->
   Bin = iolist_to_binary(wsHttp2Frame:pingFrame(<<"abcdefgh">>)),
   <<A:5/binary, B/binary>> = Bin,
   {P1, []} = wsHttp2Frame:feed(wsHttp2Frame:new(), A),
   {_P2, [{frame, ping, 0, 0, <<"abcdefgh">>}]} = wsHttp2Frame:feed(P1, B).

headers_continuation_helper_test() ->
   Block = binary:copy(<<"h">>, 100),
   Io = wsHttp2Frame:headersFrames(Block, 1, 40),
   {_P, Frames} = wsHttp2Frame:feed(wsHttp2Frame:new(), iolist_to_binary(Io)),
   ?assertMatch([
      {frame, headers, 0, 1, _},
      {frame, continuation, 0, 1, _},
      {frame, continuation, ?END_HEADERS, 1, _}
   ], Frames).

data_frames_end_stream_helper_test() ->
   Body = binary:copy(<<"x">>, 40),
   Io = wsHttp2Frame:dataFrames(Body, 3, 16),
   {_P, Frames} = wsHttp2Frame:feed(wsHttp2Frame:new(), iolist_to_binary(Io)),
   ?assertMatch([{frame, data, 0, 3, _}, {frame, data, 0, 3, _}, {frame, data, ?END_STREAM, 3, _}], Frames).

data_frames_open_batch_helper_test() ->
   Body = binary:copy(<<"x">>, 40),
   Io = wsHttp2Frame:dataFrames(Body, 3, 16, false),
   {_P, Frames} = wsHttp2Frame:feed(wsHttp2Frame:new(), iolist_to_binary(Io)),
   ?assertMatch([
      {frame, data, 0, 3, _},
      {frame, data, 0, 3, _},
      {frame, data, 0, 3, _}
   ], Frames).


hpack_static_decode_regression_test() ->
   {ok, [{<<":method">>, <<"GET">>}], _} =
      wsHpack:decode(<<16#82>>, wsHpack:new()).

hpack_dynamic_table_reuse_test() ->
   H = [
      {<<":method">>, <<"POST">>},
      {<<":scheme">>, <<"https">>},
      {<<":path">>, <<"/echo">>},
      {<<":authority">>, <<"localhost">>},
      {<<"content-type">>, <<"application/json">>},
      {<<"x-long-header">>, <<"this value is intentionally compressible compressible compressible">>}
   ],
   {Enc1, E1} = wsHpack:encode(H, wsHpack:new()),
   {ok, H, D1} = wsHpack:decode(iolist_to_binary(Enc1), wsHpack:new()),
   {Enc2, _E2} = wsHpack:encode(H, E1),
   {ok, H, _D2} = wsHpack:decode(iolist_to_binary(Enc2), D1),
   ?assert(iolist_size(Enc2) < iolist_size(Enc1)).

hpack_dynamic_table_eviction_roundtrip_test() ->
   %% Tiny table forces eviction on almost every new literal. The test checks
   %% encoder/decoder context stays synchronized across repeated evictions.
   E0 = wsHpack:setMax(128, wsHpack:new()),
   D0 = wsHpack:new(128),
   H1 = [{<<"x-a">>, binary:copy(<<"a">>, 48)}],
   H2 = [{<<"x-b">>, binary:copy(<<"b">>, 48)}],
   H3 = [{<<"x-c">>, binary:copy(<<"c">>, 48)}],
   {B1, E1} = wsHpack:encode(H1, E0),
   {ok, H1, D1} = wsHpack:decode(iolist_to_binary(B1), D0),
   {B2, E2} = wsHpack:encode(H2, E1),
   {ok, H2, D2} = wsHpack:decode(iolist_to_binary(B2), D1),
   {B3, E3} = wsHpack:encode(H3, E2),
   {ok, H3, D3} = wsHpack:decode(iolist_to_binary(B3), D2),
   {B4, _E4} = wsHpack:encode(H2, E3),
   {ok, H2, _D4} = wsHpack:decode(iolist_to_binary(B4), D3).


hpack_bad_index_regression_test() ->
   ?assertEqual({error, badIndex}, wsHpack:decode(<<16#80>>, wsHpack:new())),
   ?assertEqual({error, {badIndex, 137}}, wsHpack:decode(<<16#FF, 16#0A>>, wsHpack:new())).

hpack_integer_too_long_regression_test() ->
   Bad = <<16#FF, 16#80, 16#80, 16#80, 16#80, 16#80>>,
   ?assertEqual({error, integerTooLong}, wsHpack:decode(Bad, wsHpack:new())).

hpack_size_update_position_regression_test() ->
   Ctx = wsHpack:new(4096),
   ?assertEqual({error, sizeUpdateNotAtStart}, wsHpack:decode(<<16#82, 16#20>>, Ctx)),
   ?assertMatch({ok, [{<<":method">>, <<"GET">>}], _}, wsHpack:decode(<<16#20, 16#82>>, Ctx)).

hpack_bad_table_size_regression_test() ->
   ?assertEqual({error, {badTableSize, 8192}}, wsHpack:decode(<<16#3F, 16#E1, 16#3F>>, wsHpack:new(4096))).

hpack_incomplete_regression_test() ->
   ?assertEqual({error, incomplete}, wsHpack:decode(<<16#40, 16#03, $a>>, wsHpack:new())),
   ?assertEqual({error, incomplete}, wsHpack:decode(<<16#40>>, wsHpack:new())).

hpack_bad_huffman_regression_test() ->
   ?assertEqual({error, badHuffman}, wsHpack:decode(<<16#40, 16#81, 16#FF>>, wsHpack:new())).

window_update_validation_regression_test() ->
   ?assertEqual({ok, 1}, wsHttp2Frame:windowUpdateIncrement(<<0:1, 1:31>>)),
   ?assertEqual({error, zeroIncrement}, wsHttp2Frame:windowUpdateIncrement(<<0:1, 0:31>>)).

ping_size_validation_regression_test() ->
   ?assertEqual({ok, <<"12345678">>}, wsHttp2Frame:pingData(<<"12345678">>)),
   ?assertEqual({error, badPing}, wsHttp2Frame:pingData(<<"short">>)).

http2_respects_peer_header_list_limit_test_() ->
   {timeout, 20, fun respectsPeerHeaderLimit/0}.

respectsPeerHeaderLimit() ->
   {ok, _} = application:ensure_all_started(eWSrv),
   Name = ws_http2_peer_header_limit_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {ok, _} = eWSrv:openSrv(Name, 0, [{http2, true}, {wsMod, wsHttp2TestHandler}]),
      ListenerName = ntCom:lsName(tcp, Name),
      Port = ntTcpListener:getListenPort(ListenerName),
      {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [binary, {packet, raw}, {active, false}, {nodelay, true}], 5000),

      %% Advertise a deliberately tiny response field-section limit.
      ok = gen_tcp:send(Sock, [?PREFACE, wsHttp2Frame:settingsFrame([{max_header_list_size, 64}])]),
      {Parser1, _ServerFrames} = recvUntil(
         fun hasSettings/1, Sock, wsHttp2Frame:new(), [], 5000),
      ok = gen_tcp:send(Sock, wsHttp2Frame:ackFrame()),

      Headers = [
         {<<":method">>, <<"GET">>},
         {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>},
         {<<":path">>, <<"/one">>}
      ],
      {Block, _Tx} = wsHpack:encode(Headers, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, true)),

      IsRst = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _Flags, 1, Payload}) ->
            wsHttp2Frame:rstStreamCode(Payload) =:= {ok, internal_error};
         (_) -> false
      end, Fs) end,
      {_Parser2, Frames} = recvUntil(IsRst, Sock, Parser1, [], 5000),
      ?assert(IsRst(Frames)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

hpack_size_update_emits_minimum_before_restore_test() ->
   Ctx0 = wsHpack:new(),
   Ctx1 = wsHpack:setMax(0, Ctx0),
   Ctx2 = wsHpack:setMax(4096, Ctx1),
   {Enc, _} = wsHpack:encode([{<<":method">>, <<"GET">>}], Ctx2),
   %% 先把动态表收到 0，再恢复 4096，最后才是索引 :method GET。
   ?assertEqual(<<16#20, 16#3F, 16#E1, 16#1F, 16#82>>, iolist_to_binary(Enc)).

http2_empty_continuation_is_limited_test_() ->
   {timeout, 20, fun emptyContinuationLimited/0}.

emptyContinuationLimited() ->
   Name = ws_http2_cont_limit_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      Headers = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/one">>}
      ],
      {Block, _} = wsHpack:encode(Headers, wsHpack:new()),
      EmptyConts = [wsHttp2Frame:frame(continuation, 1, <<>>, 0) || _ <- lists:seq(1, 40)],
      ok = gen_tcp:send(Sock, [wsHttp2Frame:frame(headers, 1, Block, 0) | EmptyConts]),
      IsGoaway = fun(Fs) -> lists:any(fun
         ({frame, goaway, _, 0, Payload}) ->
            case wsHttp2Frame:goawayFields(Payload) of
               {ok, _, enhance_your_calm, _} -> true;
               _ -> false
            end;
         (_) -> false
      end, Fs) end,
      {_Parser2, Frames} = recvUntil(IsGoaway, Sock, Parser1, [], 5000),
      ?assert(IsGoaway(Frames)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_headers_on_closed_stream_test_() ->
   {timeout, 20, fun headersOnClosedStream/0}.

headersOnClosedStream() ->
   Name = ws_http2_closed_headers_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      H = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/one">>}
      ],
      {B1, Tx} = wsHpack:encode(H, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B1, 1, 16384, true)),
      {Parser2, Frames1} = recvUntil(fun(Fs) -> streamEnded(1, Fs) end, Sock, Parser1, [], 5000),
      {B2, _} = wsHpack:encode(H, Tx),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B2, 1, 16384, true)),
      IsClosed = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _, 1, Payload}) ->
            wsHttp2Frame:rstStreamCode(Payload) =:= {ok, stream_closed};
         (_) -> false
      end, Fs) end,
      {Parser3, Frames2} = recvUntil(IsClosed, Sock, Parser2, Frames1, 5000),
      ?assert(IsClosed(Frames2)),
      H3 = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/two">>}
      ],
      {B3, _} = wsHpack:encode(H3, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B3, 3, 16384, true)),
      {_Parser4, Frames3} = recvUntil(fun(Fs) -> streamEnded(3, Fs) end, Sock, Parser3, Frames2, 5000),
      {_HMap, BMap} = decodeResponses(Frames3),
      ?assertEqual(<<"two">>, maps:get(3, BMap)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_rejects_mismatched_scheme_test_() ->
   {timeout, 20, fun rejectsMismatchedScheme/0}.

rejectsMismatchedScheme() ->
   Name = ws_http2_scheme_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      H = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/one">>}
      ],
      {Block, _} = wsHpack:encode(H, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, true)),
      IsRst = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _, 1, Payload}) ->
            wsHttp2Frame:rstStreamCode(Payload) =:= {ok, protocol_error};
         (_) -> false
      end, Fs) end,
      {_Parser2, Frames} = recvUntil(IsRst, Sock, Parser1, [], 5000),
      ?assert(IsRst(Frames)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_same_buffer_respects_recv_window_test_() ->
   {timeout, 20, fun sameBufferRespectsRecvWindow/0}.

http2_terminate_fails_pending_chunk_ack_test() ->
   Parent = self(),
   Worker = spawn(fun() ->
      receive
         Msg -> Parent ! {worker_ack, Msg}
      end
   end),
   State = #{
      streams => #{
         1 => #{
            pending_ack => {Worker, pending_token, self()}
         }
      }
   },
   ok = wsHttp2:terminate(State),
   receive
      {Self, {error, closed}} when Self =:= self() -> ok
   after 1000 ->
      ?assert(false)
   end,
   receive
      {worker_ack, {h2_chunk_ack, pending_token, {error, closed}}} -> ok
   after 1000 ->
      ?assert(false)
   end.

http2_rejects_invalid_field_syntax_test_() ->
   {timeout, 20, fun rejectsInvalidFieldSyntax/0}.

rejectsInvalidFieldSyntax() ->
   Name = ws_http2_bad_field_syntax_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      Base = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/one">>}
      ],
      {B1, Tx1} = wsHpack:encode(Base ++ [{<<"x bad">>, <<"v">>}], wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B1, 1, 16384, true)),
      IsRst1 = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _, 1, Payload}) ->
            wsHttp2Frame:rstStreamCode(Payload) =:= {ok, protocol_error};
         (_) -> false
      end, Fs) end,
      {Parser2, Frames1} = recvUntil(IsRst1, Sock, Parser1, [], 5000),
      ?assert(IsRst1(Frames1)),

      {B3, _Tx2} = wsHpack:encode(Base ++ [{<<"x-test">>, <<" leading">>}], Tx1),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(B3, 3, 16384, true)),
      IsRst3 = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _, 3, Payload}) ->
            wsHttp2Frame:rstStreamCode(Payload) =:= {ok, protocol_error};
         (_) -> false
      end, Fs) end,
      {_Parser3, Frames2} = recvUntil(IsRst3, Sock, Parser2, Frames1, 5000),
      ?assert(IsRst3(Frames2)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_rejects_signed_content_length_test_() ->
   {timeout, 20, fun rejectsSignedContentLength/0}.

rejectsSignedContentLength() ->
   Name = ws_http2_signed_cl_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      H = [
         {<<":method">>, <<"POST">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/echo">>},
         {<<"content-length">>, <<"+0">>}
      ],
      {Block, _} = wsHpack:encode(H, wsHpack:new()),
      ok = gen_tcp:send(Sock, wsHttp2Frame:headersFrames(Block, 1, 16384, true)),
      IsRst = fun(Fs) -> lists:any(fun
         ({frame, rst_stream, _, 1, Payload}) ->
            wsHttp2Frame:rstStreamCode(Payload) =:= {ok, protocol_error};
         (_) -> false
      end, Fs) end,
      {_Parser2, Frames} = recvUntil(IsRst, Sock, Parser1, [], 5000),
      ?assert(IsRst(Frames)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_goaway_no_error_drains_open_stream_test_() ->
   {timeout, 20, fun goawayDrainsOpenStream/0}.

goawayDrainsOpenStream() ->
   Name = ws_http2_goaway_drain_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      H = [
         {<<":method">>, <<"GET">>}, {<<":scheme">>, <<"http">>},
         {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/slow">>}
      ],
      {Block, _} = wsHpack:encode(H, wsHpack:new()),
      ok = gen_tcp:send(Sock, [
         wsHttp2Frame:headersFrames(Block, 1, 16384, true),
         %% A client GOAWAY identifies server-initiated streams; this server
         %% does not push, so Last-Stream-ID=0 is the normal graceful value.
         wsHttp2Frame:goawayFrame(0, no_error)
      ]),
      {_Parser2, Frames} = recvUntil(fun(Fs) -> streamEnded(1, Fs) end,
         Sock, Parser1, [], 3000),
      {_Headers, Body} = decodeResponse(Frames),
      ?assertEqual(<<"slow">>, Body),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

http2_ignores_unknown_flag_bits_test_() ->
   {timeout, 20, fun ignoresUnknownFlagBits/0}.

ignoresUnknownFlagBits() ->
   Name = ws_http2_unknown_flags_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {Sock, Parser1} = openPriorKnowledge(Name, wsHttp2TestHandler),
      Payload = <<"flagtest">>,
      %% RFC 9113 §4.1: undefined flag bits must be ignored on receipt.
      ok = gen_tcp:send(Sock, wsHttp2Frame:frame(ping, 0, Payload, 16#80)),
      IsPong = fun(Fs) -> lists:any(fun
         ({frame, ping, Flags, 0, P}) -> P =:= Payload andalso Flags band 1 =/= 0;
         (_) -> false
      end, Fs) end,
      {_Parser2, Frames} = recvUntil(IsPong, Sock, Parser1, [], 5000),
      ?assert(IsPong(Frames)),
      gen_tcp:close(Sock)
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

goaway_reserved_bit_is_ignored_test() ->
   Payload = <<1:1, 3:31, 0:32, "debug">>,
   ?assertEqual({ok, 3, no_error, <<"debug">>}, wsHttp2Frame:goawayFields(Payload)).

hpack_decoder_can_restore_table_size_test() ->
   Ctx0 = wsHpack:new(4096),
   %% Dynamic table size 0 is legal and clears the table.
   {ok, [], Ctx1} = wsHpack:decode(<<16#20>>, Ctx0),
   %% A later header block may restore it up to SETTINGS_HEADER_TABLE_SIZE.
   Restore4096AndGet = <<16#3F, 16#E1, 16#1F, 16#82>>,
   ?assertMatch(
      {ok, [{<<":method">>, <<"GET">>}], _},
      wsHpack:decode(Restore4096AndGet, Ctx1)
   ).

%% 同一份二进制里的 DATA 必须共用进入 handleData 之前的接收窗口。
%% 按 TCP 分段送进去会在两次 recv 之间补窗口，测不到这一点。
sameBufferRespectsRecvWindow() ->
   {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
   {ok, Port} = inet:port(Listen),
   Parent = self(),
   ClientPid = spawn(fun() ->
      {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
      Parent ! connected,
      receive stop -> gen_tcp:close(Client) end
   end),
   {ok, Socket} = gen_tcp:accept(Listen),
   receive connected -> ok after 2000 -> error(accept_timeout) end,
   H2 = wsHttp2:new(Socket, wsHttp2TestHandler, http, 8 * 1024 * 1024, 64 * 1024, 30000),
   {ok, H2A} = wsHttp2:start(H2),
   Headers = [
      {<<":method">>, <<"POST">>}, {<<":scheme">>, <<"http">>},
      {<<":authority">>, <<"127.0.0.1">>}, {<<":path">>, <<"/echo">>}
   ],
   {Block, _} = wsHpack:encode(Headers, wsHpack:new()),
   Chunk = binary:copy(<<$a>>, 16384),
   Data = [wsHttp2Frame:frame(data, 1, Chunk, 0) || _ <- lists:seq(1, 5)],
   All = iolist_to_binary([
      ?PREFACE,
      wsHttp2Frame:settingsFrame([]),
      wsHttp2Frame:headersFrames(Block, 1, 16384, false)
      | Data
   ]),
   {stop, {http2, connection_receive_window_exceeded}, EndState} = wsHttp2:handleData(All, H2A),
   wsHttp2:terminate(EndState),
   gen_tcp:close(Socket),
   gen_tcp:close(Listen),
   ClientPid ! stop.
