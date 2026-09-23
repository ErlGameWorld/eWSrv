-module(wsStream_tests).

-include_lib("eunit/include/eunit.hrl").

client_disconnect_stops_stream_connection_test() ->
   withServer(tcp, fun(Port) -> disconnectTest(tcp, Port) end).

tls_client_disconnect_stops_stream_connection_test() ->
   withServer(tls, fun(Port) -> disconnectTest(tls, Port) end).

disconnectTest(Transport, Port) ->
      {ok, Socket} = connect(Transport, Port),
      ok = transportSend(Transport, Socket, request(<<"/disconnect">>, <<"keep-alive">>)),
      {ok, Response} = transportRecv(Transport, Socket, 2000),
      ?assertNotEqual(nomatch, binary:match(Response, <<"200 OK">>)),
      Conn = receive
         {stream_connection, Pid} -> Pid
      after 2000 ->
         error(stream_connection_not_reported)
      end,
      ok = transportClose(Transport, Socket),
      receive
         {stream_connection_down, Conn, _Reason} -> ok;
         {stream_connection_leaked, Conn} -> error(stream_connection_leaked)
      after 2000 ->
         error(stream_disconnect_timeout)
      end.

server_closed_stream_can_keep_connection_alive_test() ->
   withServer(tcp, fun(Port) ->
      {ok, Socket} = connect(tcp, Port),
      ok = gen_tcp:send(Socket, request(<<"/finite">>, <<"keep-alive">>)),
      First = recvUntil(Socket, <<"0\r\n\r\n">>, <<>>, 2000),
      ?assertNotEqual(nomatch, binary:match(First, <<"done">>)),
      ok = gen_tcp:send(Socket, request(<<"/hello">>, <<"close">>)),
      Second = recvUntil(Socket, <<"hello">>, <<>>, 2000),
      ?assertNotEqual(nomatch, binary:match(Second, <<"200 OK">>)),
      ?assertNotEqual(nomatch, binary:match(Second, <<"hello">>)),
      gen_tcp:close(Socket)
   end).

pipeline_arriving_during_stream_is_processed_after_stream_test() ->
   withServer(tcp, fun(Port) ->
      {ok, Socket} = connect(tcp, Port),
      ok = gen_tcp:send(Socket, request(<<"/delayed-finite">>, <<"keep-alive">>)),
      FirstHead = recvUntil(Socket, <<"\r\n\r\n">>, <<>>, 2000),
      ?assertNotEqual(nomatch, binary:match(FirstHead, <<"transfer-encoding: chunked">>)),
      %% Send the next request while the first response is still streaming.
      ok = gen_tcp:send(Socket, request(<<"/hello">>, <<"close">>)),
      Tail = recvUntil(Socket, <<"hello">>, <<>>, 2000),
      All = <<FirstHead/binary, Tail/binary>>,
      ?assertNotEqual(nomatch, binary:match(All, <<"done">>)),
      ?assertEqual(2, length(binary:matches(All, <<"HTTP/1.1 200 OK">>))),
      gen_tcp:close(Socket)
   end).

withServer(Transport, Test) ->
   flushMailbox(),
   true = register(ws_stream_test_owner, self()),
   {ok, _} = eWSrv:start(),
   Port = freePort(),
   Name = list_to_atom("ws_stream_test_" ++ integer_to_list(Port)),
   try
      {ok, _} = eWSrv:openSrv(Name, Port, serverOpts(Transport) ++ [
         {wsMod, wsStreamTestHandler},
         {tcpOpts, [{ip, {127, 0, 0, 1}}]}
      ]),
      Test(Port)
   after
      try eWSrv:closeSrv(Name) catch _:_ -> ok end,
      unregister(ws_stream_test_owner),
      flushMailbox()
   end.

serverOpts(tcp) ->
   [];
serverOpts(tls) ->
   Priv = code:priv_dir(eWSrv),
   [{sslOpts, [{certfile, filename:join(Priv, "demo.crt")}, {keyfile, filename:join(Priv, "demo.key")}]}].

freePort() ->
   {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
   {ok, {{127, 0, 0, 1}, Port}} = inet:sockname(Socket),
   ok = gen_tcp:close(Socket),
   Port.

connect(Transport, Port) ->
   connect(Transport, Port, 20).

connect(_Transport, _Port, 0) ->
   {error, listener_not_ready};
connect(Transport, Port, Attempts) ->
   Result = case Transport of
      tcp -> gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 200);
      tls -> ssl:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {verify, verify_none}], 1000)
   end,
   case Result of
      {ok, _} = Ok -> Ok;
      {error, econnrefused} ->
         timer:sleep(10),
         connect(Transport, Port, Attempts - 1);
      Error -> Error
   end.

transportSend(tcp, Socket, Data) ->
   gen_tcp:send(Socket, Data);
transportSend(tls, Socket, Data) ->
   ssl:send(Socket, Data).

transportRecv(tcp, Socket, Timeout) ->
   gen_tcp:recv(Socket, 0, Timeout);
transportRecv(tls, Socket, Timeout) ->
   ssl:recv(Socket, 0, Timeout).

transportClose(tcp, Socket) ->
   gen_tcp:close(Socket);
transportClose(tls, Socket) ->
   ssl:close(Socket).

request(Path, Connection) ->
   <<"GET ", Path/binary, " HTTP/1.1\r\n", "Host: 127.0.0.1\r\n", "Connection: ", Connection/binary, "\r\n\r\n">>.

recvUntil(Socket, Needle, Acc, Timeout) ->
   case binary:match(Acc, Needle) of
      nomatch ->
         case gen_tcp:recv(Socket, 0, Timeout) of
            {ok, Data} -> recvUntil(Socket, Needle, <<Acc/binary, Data/binary>>, Timeout);
            {error, Reason} -> error({recv_failed, Reason, Acc})
         end;
      _ -> Acc
   end.

flushMailbox() ->
   receive _ -> flushMailbox() after 0 -> ok end.
