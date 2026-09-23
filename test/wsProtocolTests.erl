-module(wsProtocolTests).

-include_lib("eunit/include/eunit.hrl").
-include("wsCom.hrl").

header_value_control_character_test() ->
   ?assert(wsUtil:noCtlChars(<<"ok\tvalue">>)),
   ?assertNot(wsUtil:noCtlChars(<<1>>)),
   ?assertNot(wsUtil:noCtlChars(<<127>>)),
   ?assertNot(wsUtil:noCtlChars(<<"bad\rvalue">>)).

conflicting_content_length_test() ->
   Req = <<"POST / HTTP/1.1\r\n", "Host: localhost\r\n", "Content-Length: 4\r\n", "Content-Length: 5\r\n", "\r\n" >>,
   ?assertMatch({error, conflicting_content_length}, wsHttpProtocol:request(reqLine, Req, undefined, #wsState{})).

content_length_rejects_signed_decimal_test() ->
   Req = <<"POST / HTTP/1.1\r\n", "Host: localhost\r\n",
      "Content-Length: +4\r\n", "\r\n", "test">>,
   ?assertMatch(
      {error, invalid_content_length},
      wsHttpProtocol:request(reqLine, Req, undefined, #wsState{})
   ).

content_length_transfer_encoding_conflict_test() ->
   Req = <<
      "POST / HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Content-Length: 4\r\n",
      "Transfer-Encoding: chunked\r\n",
      "\r\n"
   >>,
   State = #wsState{chunkedSupp = true},
   ?assertMatch(
      {error, content_length_transfer_encoding_conflict},
      wsHttpProtocol:request(reqLine, Req, undefined, State)
   ).

missing_host_http11_test() ->
   Req = <<"GET / HTTP/1.1\r\n\r\n">>,
   ?assertMatch({error, missing_host}, wsHttpProtocol:request(reqLine, Req, undefined, #wsState{})).

origin_form_transport_scheme_test() ->
   Req = <<"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n">>,
   {wsDone, HttpState} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{}),
   HttpReq = HttpState#wsState.wsReq,
   ?assertEqual(<<"http">>, HttpReq#wsReq.scheme),
   ?assertEqual(80, HttpReq#wsReq.port),
   ?assertEqual(<<"/">>, HttpReq#wsReq.path),
   ?assertEqual([], HttpReq#wsReq.args),
   {wsDone, HttpsState} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{isSsl = true}),
   HttpsReq = HttpsState#wsState.wsReq,
   ?assertEqual(<<"https">>, HttpsReq#wsReq.scheme),
   ?assertEqual(443, HttpsReq#wsReq.port).

origin_form_query_keeps_existing_semantics_test() ->
   Req = <<"GET /params?a=1&b=two HTTP/1.1\r\nHost: example.com\r\n\r\n">>,
   {wsDone, State} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{}),
   WsReq = State#wsState.wsReq,
   ?assertEqual(<<"/params">>, WsReq#wsReq.path),
   Args = maps:from_list(WsReq#wsReq.args),
   ?assertEqual(<<"1">>, maps:get(<<"a">>, Args)),
   ?assertEqual(<<"two">>, maps:get(<<"b">>, Args)).

origin_form_fragment_is_rejected_test() ->
   Req = <<"GET /hello#frag HTTP/1.1\r\nHost: example.com\r\n\r\n">>,
   ?assertMatch({error, invalid_uri},
      wsHttpProtocol:request(reqLine, Req, undefined, #wsState{})).

connection_tokens_are_cached_during_parse_test() ->
   Req = <<"GET / HTTP/1.1\r\nHost: example.com\r\nConnection: Keep-Alive, Foo\r\n\r\n">>,
   {wsDone, State} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{}),
   ?assertEqual(false, State#wsState.reqConnClose),
   ?assertEqual(true, State#wsState.reqConnKeepAlive).

options_asterisk_request_target_test() ->
   Req = <<"OPTIONS * HTTP/1.1\r\nHost: example.com\r\n\r\n">>,
   {wsDone, State} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{}),
   ?assertEqual(<<"*">>, (State#wsState.wsReq)#wsReq.path).

asterisk_requires_options_test() ->
   Req = <<"GET * HTTP/1.1\r\nHost: example.com\r\n\r\n">>,
   ?assertMatch({error, invalid_request_target},
      wsHttpProtocol:request(reqLine, Req, undefined, #wsState{})).

connect_authority_form_test() ->
   Req = <<"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n">>,
   {wsDone, State} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{}),
   WsReq = State#wsState.wsReq,
   ?assertEqual('CONNECT', WsReq#wsReq.method),
   ?assertEqual(<<"example.com">>, WsReq#wsReq.host),
   ?assertEqual(443, WsReq#wsReq.port),
   ?assertEqual(<<"example.com:443">>, WsReq#wsReq.path).

patch_method_is_normalized_test() ->
   Req = <<"PATCH /resource HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n">>,
   {wsDone, State} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{}),
   ?assertEqual('PATCH', (State#wsState.wsReq)#wsReq.method).

origin_form_explicit_host_port_test() ->
   Req = <<"GET / HTTP/1.1\r\nHost: example.com:9443\r\n\r\n">>,
   {wsDone, State} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{isSsl = true}),
   WsReq = State#wsState.wsReq,
   ?assertEqual(<<"https">>, WsReq#wsReq.scheme),
   ?assertEqual(9443, WsReq#wsReq.port).

chunked_split_boundary_test() ->
   Part1 = <<"POST / HTTP/1.1\r\n", "Host: localhost\r\n", "Transfer-Encoding: chunked\r\n", "\r\n", "4" >>,
   State0 = #wsState{chunkedSupp = true},
   {ok, State1} = wsHttpProtocol:request(reqLine, Part1, undefined, State0),
   Part2 = <<"\r\nWiki\r\n0\r\n\r\n">>,
   {wsDone, State2} = wsHttpProtocol:request(wsBody, Part2, undefined, State1),
   ?assertEqual(<<"Wiki">>, (State2#wsState.wsReq)#wsReq.body),
   ?assertEqual(<<>>, State2#wsState.buffer).

chunked_pipeline_rest_test() ->
   Req = <<
      "POST / HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Transfer-Encoding: chunked\r\n",
      "\r\n",
      "1\r\na\r\n0\r\n\r\n",
      "GET /next HTTP/1.1\r\nHost: localhost\r\n\r\n"
   >>,
   {wsDone, State} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{chunkedSupp = true}),
   ?assertEqual(<<"a">>, (State#wsState.wsReq)#wsReq.body),
   ?assertMatch(<<"GET /next", _/binary>>, State#wsState.buffer).

chunked_trailers_are_exposed_to_handler_test() ->
   Req = <<
      "POST / HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Transfer-Encoding: chunked\r\n",
      "\r\n",
      "1\r\na\r\n0\r\n",
      "X-Checksum: ok\r\n\r\n"
   >>,
   {wsDone, State} = wsHttpProtocol:request(reqLine, Req, undefined, #wsState{chunkedSupp = true}),
   WsReq = State#wsState.wsReq,
   ?assertEqual(false, lists:any(fun({K, _}) ->
      wsUtil:headerNameEq(K, <<"X-Checksum">>)
   end, WsReq#wsReq.headers)),
   ?assert(lists:any(fun({K, V}) ->
      wsUtil:headerNameEq(K, <<"X-Checksum">>) andalso V =:= <<"ok">>
   end, WsReq#wsReq.trailers)).

chunked_forbidden_trailer_is_rejected_test() ->
   Req = <<
      "POST / HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Transfer-Encoding: chunked\r\n",
      "\r\n",
      "1\r\na\r\n0\r\n",
      "Content-Length: 1\r\n\r\n"
   >>,
   ?assertMatch({error, forbidden_trailer},
      wsHttpProtocol:request(reqLine, Req, undefined, #wsState{chunkedSupp = true})).

websocket_handshake_header_names_are_case_insensitive_test() ->
   Key = base64:encode(<<0:128>>),
   Req = #wsReq{
      method = 'GET',
      version = {1, 1},
      headers = [
         {<<"connection">>, <<"Upgrade">>},
         {<<"UPGRADE">>, <<"websocket">>},
         {<<"sec-websocket-version">>, <<"13">>},
         {<<"SEC-WEBSOCKET-KEY">>, Key}
      ]
   },
   ?assertMatch({ok, _}, wsWebSocket:tryWsUpgrade(Req)).

websocket_subprotocol_negotiation_test() ->
   Req = #wsReq{
      headers = [
         {<<"Sec-WebSocket-Protocol">>, <<"unknown, superchat, chat">>}
      ]
   },
   {wsWebSocket, Headers} =
      wsWebSocket:handleUpgrade(wsWsProtocolTestHandler, Req, []),
   ?assertEqual(
      {<<"Sec-WebSocket-Protocol">>, <<"superchat">>},
      lists:keyfind(<<"Sec-WebSocket-Protocol">>, 1, Headers)
   ).

websocket_rejects_unmasked_client_frame_test() ->
   Frame = <<1:1, 0:3, ?WsOpText:4, 0:1, 1:7, "x">>,
   ?assertEqual({close, protocol_error}, wsWebSocket:parseWebSocketFrames(Frame, #wsState{}, [])).

websocket_frame_limit_test() ->
   %% 126-byte frame header + mask key is enough to reject before payload buffering.
   Frame = <<1:1, 0:3, ?WsOpBinary:4, 1:1, 126:7, 126:16, 0,0,0,0>>,
   State = #wsState{maxWsFrameSize = 125},
   ?assertEqual({close, message_too_big}, wsWebSocket:parseWebSocketFrames(Frame, State, [])).

websocket_rejects_oversized_outbound_control_frame_test() ->
   Payload = binary:copy(<<"x">>, 126),
   ?assertEqual(
      {error, control_frame_too_large},
      wsWebSocket:sendFrame(undefined, ?WsOpPing, Payload)
   ).

websocket_rejects_invalid_outbound_text_test() ->
   ?assertEqual(
      {error, invalid_utf8},
      wsWebSocket:sendFrame(undefined, ?WsOpText, <<16#FF>>)
   ).

websocket_rejects_fragmented_control_frame_test() ->
   Frame = <<0:1, 0:3, ?WsOpPing:4, 1:1, 0:7, 0,0,0,0>>,
   ?assertEqual({close, protocol_error}, wsWebSocket:parseWebSocketFrames(Frame, #wsState{}, [])).

%% RFC 6455 §5.7，再覆盖长度不是 4 的倍数，确认尾部单字节分支。
websocket_unmasks_payload_test() ->
   Hello = <<16#81, 16#85, 16#37, 16#fa, 16#21, 16#3d, 16#7f, 16#9f, 16#4d, 16#51, 16#58>>,
   ?assertEqual({ok, [{1, ?WsOpText, <<"Hello">>}], <<>>}, wsWebSocket:parseWebSocketFrames(Hello, #wsState{}, [])),
   Mask = <<1, 2, 3, 4>>,
   lists:foreach(fun(N) ->
      Plain = binary:copy(<<$x>>, N),
      ?assertEqual(
         {ok, [{1, ?WsOpText, Plain}], <<>>},
         wsWebSocket:parseWebSocketFrames(mask_text(Plain, Mask), #wsState{}, [])
      )
   end, [0, 1, 2, 3, 4, 5, 7, 8, 20]).

%% 1KB 分段喂入大帧：增量状态机应收齐后只解一次，结果与整包一致。
websocket_feed_chunked_large_frame_test() ->
   Mask = <<9, 8, 7, 6>>,
   Plain = binary:copy(<<"abcd">>, 64 * 1024), %% 256KB
   Frame = mask_binary_frame(Plain, Mask),
   Chunks = split_bin(Frame, 1024),
   {ok, Frames, State} = lists:foldl(fun(Chunk, {ok, AccFrames, St}) ->
      case wsWebSocket:feed(Chunk, St) of
         {ok, More, St1} -> {ok, AccFrames ++ More, St1};
         Other -> Other
      end
   end, {ok, [], #wsState{}}, Chunks),
   ?assertEqual([{1, ?WsOpBinary, Plain}], Frames),
   ?assertEqual(undefined, State#wsState.wsParse).

websocket_feed_incomplete_header_then_body_test() ->
   Mask = <<1, 2, 3, 4>>,
   Plain = <<"hello-ws">>,
   Frame = mask_text(Plain, Mask),
   <<H1:3/binary, Rest/binary>> = Frame,
   {ok, [], S1} = wsWebSocket:feed(H1, #wsState{}),
   ?assertMatch({hdr, _}, S1#wsState.wsParse),
   {ok, Frames, S2} = wsWebSocket:feed(Rest, S1),
   ?assertEqual([{1, ?WsOpText, Plain}], Frames),
   ?assertEqual(undefined, S2#wsState.wsParse).

mask_text(Plain, <<M0:8, M1:8, M2:8, M3:8>> = Key) ->
   Len = byte_size(Plain),
   true = Len < 126,
   Payload = mask_bytes(Plain, M0, M1, M2, M3, 0, <<>>),
   <<1:1, 0:3, ?WsOpText:4, 1:1, Len:7, Key/binary, Payload/binary>>.

mask_binary_frame(Plain, <<M0:8, M1:8, M2:8, M3:8>> = Key) ->
   Len = byte_size(Plain),
   Payload = mask_bytes(Plain, M0, M1, M2, M3, 0, <<>>),
   Header = if
      Len =< 16#FFFF ->
         <<1:1, 0:3, ?WsOpBinary:4, 1:1, 126:7, Len:16, Key/binary>>;
      true ->
         <<1:1, 0:3, ?WsOpBinary:4, 1:1, 127:7, Len:64, Key/binary>>
   end,
   <<Header/binary, Payload/binary>>.

split_bin(Bin, Size) ->
   split_bin(Bin, Size, []).

split_bin(<<>>, _Size, Acc) ->
   lists:reverse(Acc);
split_bin(Bin, Size, Acc) when byte_size(Bin) > Size ->
   <<Chunk:Size/binary, Rest/binary>> = Bin,
   split_bin(Rest, Size, [Chunk | Acc]);
split_bin(Bin, _Size, Acc) ->
   lists:reverse([Bin | Acc]).

mask_bytes(<<Byte:8, Rest/binary>>, M0, M1, M2, M3, Index, Acc) ->
   Mask = case Index band 3 of
      0 -> M0;
      1 -> M1;
      2 -> M2;
      _ -> M3
   end,
   mask_bytes(Rest, M0, M1, M2, M3, Index + 1, <<Acc/binary, (Byte bxor Mask):8>>);
mask_bytes(<<>>, _M0, _M1, _M2, _M3, _Index, Acc) ->
   Acc.
