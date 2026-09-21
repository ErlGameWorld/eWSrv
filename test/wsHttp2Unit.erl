-module(wsHttp2Unit).

-include_lib("eunit/include/eunit.hrl").

-define(PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(END_STREAM, 16#01).
-define(END_HEADERS, 16#04).

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

http2_prior_knowledge_integration_test_() ->
   {timeout, 20, fun priorKnowledge/0}.

priorKnowledge() ->
   {ok, _} = application:ensure_all_started(eWSrv),
   Name = ws_http2_eunit,
   _ = catch eWSrv:closeSrv(Name),
   try
      {ok, _} = eWSrv:openSrv(Name, 0, [
         {http2, true},
         {wsMod, wsTPHer},
         {chunkedSupp, true}
      ]),
      ListenerName = ntCom:lsName(tcp, Name),
      Port = ntTcpListener:getListenPort(ListenerName),
      {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port, [
         binary, {packet, raw}, {active, false}, {nodelay, true}
      ], 5000),

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
         {sslOpts, [
            {certfile, Cert},
            {keyfile, Key},
            {verify, verify_none}
         ]}
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
      ok = ssl:send(Sock, [
         wsHttp2Frame:ackFrame(),
         wsHttp2Frame:headersFrames(Block, 1, 16384, true)
      ]),
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
      ok = gen_tcp:send(Sock, [
         wsHttp2Frame:windowUpdateFrame(0, 50000),
         wsHttp2Frame:windowUpdateFrame(1, 50000)
      ]),
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
   {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port,
      [binary, {packet, raw}, {active, false}, {nodelay, true}], 5000),
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
