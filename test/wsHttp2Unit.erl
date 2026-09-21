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
   {HeaderBlock, _} = collectHeaderBlock(Frames, none, []),
   {ok, Headers, _Rx} = wsHpack:decode(HeaderBlock, wsHpack:new()),
   Body = iolist_to_binary([P || {frame, data, _Flags, 1, P} <- Frames]),
   {Headers, Body}.

collectHeaderBlock([], _Pending, Acc) ->
   {iolist_to_binary(lists:reverse(Acc)), []};
collectHeaderBlock([{frame, headers, Flags, 1, Payload} | Rest], none, _Acc) ->
   case Flags band ?END_HEADERS =/= 0 of
      true -> {Payload, Rest};
      false -> collectHeaderBlock(Rest, pending, [Payload])
   end;
collectHeaderBlock([{frame, continuation, Flags, 1, Payload} | Rest], pending, Acc) ->
   case Flags band ?END_HEADERS =/= 0 of
      true -> {iolist_to_binary(lists:reverse([Payload | Acc])), Rest};
      false -> collectHeaderBlock(Rest, pending, [Payload | Acc])
   end;
collectHeaderBlock([_ | Rest], Pending, Acc) ->
   collectHeaderBlock(Rest, Pending, Acc).
