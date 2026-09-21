-module(wsProtocolTests).

-include_lib("eunit/include/eunit.hrl").
-include("wsCom.hrl").

conflicting_content_length_test() ->
   Req = <<
      "POST / HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Content-Length: 4\r\n",
      "Content-Length: 5\r\n",
      "\r\n"
   >>,
   ?assertMatch(
      {error, conflicting_content_length},
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
   ?assertMatch(
      {error, missing_host},
      wsHttpProtocol:request(reqLine, Req, undefined, #wsState{})
   ).

chunked_split_boundary_test() ->
   Part1 = <<
      "POST / HTTP/1.1\r\n",
      "Host: localhost\r\n",
      "Transfer-Encoding: chunked\r\n",
      "\r\n",
      "4"
   >>,
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
   {wsDone, State} = wsHttpProtocol:request(
      reqLine, Req, undefined, #wsState{chunkedSupp = true}
   ),
   ?assertEqual(<<"a">>, (State#wsState.wsReq)#wsReq.body),
   ?assertMatch(<<"GET /next", _/binary>>, State#wsState.buffer).

websocket_rejects_unmasked_client_frame_test() ->
   Frame = <<1:1, 0:3, ?WsOpText:4, 0:1, 1:7, "x">>,
   ?assertEqual(
      {close, protocol_error},
      wsWebSocket:parseWebSocketFrames(Frame, #wsState{}, [])
   ).

websocket_frame_limit_test() ->
   %% 126-byte frame header + mask key is enough to reject before payload buffering.
   Frame = <<1:1, 0:3, ?WsOpBinary:4, 1:1, 126:7, 126:16, 0,0,0,0>>,
   State = #wsState{maxWsFrameSize = 125},
   ?assertEqual(
      {close, message_too_big},
      wsWebSocket:parseWebSocketFrames(Frame, State, [])
   ).

websocket_rejects_fragmented_control_frame_test() ->
   Frame = <<0:1, 0:3, ?WsOpPing:4, 1:1, 0:7, 0,0,0,0>>,
   ?assertEqual(
      {close, protocol_error},
      wsWebSocket:parseWebSocketFrames(Frame, #wsState{}, [])
   ).
