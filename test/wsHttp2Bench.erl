-module(wsHttp2Bench).

-export([run/0, run/1]).

-define(PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(END_STREAM, 16#01).

%% @doc 本机 HTTP/2 prior-knowledge benchmark。
%% 在同一条 TCP connection 上并发多个 stream，尽量隔离连接建立与公网开销。
%%
%% 使用:
%%   rebar3 as test shell
%%   1> wsHttp2Bench:run().
%%   2> wsHttp2Bench:run(#{requests => 20000, concurrency => 64}).
%%
%% 返回 map，同时打印 requests/sec、p50/p95/p99。
run() ->
   run(#{
      requests => 10000,
      concurrency => 32,
      warmup => 1000,
      path => <<"/one">>,
      max_body => 8 * 1024 * 1024,
      quiet => false
   }).

run(Opts) when is_map(Opts) ->
   Requests = maps:get(requests, Opts, 10000),
   Concurrency0 = maps:get(concurrency, Opts, 32),
   Concurrency = erlang:max(1, erlang:min(100, Concurrency0)),
   Warmup = maps:get(warmup, Opts, 1000),
   Path = maps:get(path, Opts, <<"/one">>),
   MaxBody = maps:get(max_body, Opts, 8 * 1024 * 1024),
   Quiet = maps:get(quiet, Opts, false),
   true = is_integer(Requests) andalso Requests > 0,

   {ok, _} = application:ensure_all_started(eWSrv),
   Name = ws_http2_bench,
   _ = catch eWSrv:closeSrv(Name),
   try
      {ok, _} = eWSrv:openSrv(Name, 0, [
         {http2, true},
         {wsMod, wsHttp2TestHandler},
         {maxSize, MaxBody},
         {keepAliveTimeout, 300000}
      ]),
      ListenerName = ntCom:lsName(tcp, Name),
      Port = ntTcpListener:getListenPort(ListenerName),
      {ok, Sock} = gen_tcp:connect({127,0,0,1}, Port,
         [binary, {packet, raw}, {active, false}, {nodelay, true}], 5000),

      {Parser0, _ServerFrames} = handshake(Sock),

      %% Warm-up uses the same connection/HPACK contexts, but timings are discarded.
      {Parser1, Tx1, NextId1, _} =
         benchBatches(Sock, Parser0, wsHpack:new(), 1,
            Warmup, Concurrency, Path, []),

      StartUs = erlang:monotonic_time(microsecond),
      {Parser, _Tx, _NextId, LatUs} =
         benchBatches(Sock, Parser1, Tx1, NextId1,
            Requests, Concurrency, Path, []),
      _ = Parser,
      TotalUs = erlang:monotonic_time(microsecond) - StartUs,
      ok = gen_tcp:close(Sock),

      Sorted = lists:sort(LatUs),
      Result = #{
         protocol => http2,
         requests => Requests,
         concurrency => Concurrency,
         streams => Concurrency,
         connections => 1,
         warmup => Warmup,
         total_ms => TotalUs / 1000,
         requests_per_sec => Requests * 1000000 / erlang:max(1, TotalUs),
         latency_avg_ms => avg(Sorted) / 1000,
         latency_p50_ms => percentile(Sorted, 0.50) / 1000,
         latency_p95_ms => percentile(Sorted, 0.95) / 1000,
         latency_p99_ms => percentile(Sorted, 0.99) / 1000
      },
      Quiet orelse printResult(Result),
      Result
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

handshake(Sock) ->
   ok = gen_tcp:send(Sock, [?PREFACE, wsHttp2Frame:settingsFrame([])]),
   {Parser, Frames} = recvUntilSettings(Sock, wsHttp2Frame:new(), [], 5000),
   ok = gen_tcp:send(Sock, wsHttp2Frame:ackFrame()),
   {Parser, Frames}.

recvUntilSettings(Sock, Parser0, Acc, Timeout) ->
   case hasServerSettings(Acc) of
      true ->
         {Parser0, Acc};
      false ->
         {ok, Bin} = gen_tcp:recv(Sock, 0, Timeout),
         {Parser, Frames} = wsHttp2Frame:feed(Parser0, Bin),
         recvUntilSettings(Sock, Parser, Acc ++ Frames, Timeout)
   end.

hasServerSettings(Frames) ->
   lists:any(fun
      ({frame, settings, Flags, 0, _}) -> Flags band 1 =:= 0;
      (_) -> false
   end, Frames).

benchBatches(_Sock, Parser, Tx, NextId, 0, _Concurrency, _Path, LatAcc) ->
   {Parser, Tx, NextId, LatAcc};
benchBatches(Sock, Parser0, Tx0, NextId0, Remaining, Concurrency, Path, LatAcc0) ->
   Count = erlang:min(Remaining, Concurrency),
   {Frames, Tx, Ids, NextId} = makeBatch(Count, NextId0, Tx0, Path, [], []),
   SentUs = erlang:monotonic_time(microsecond),
   Pending = maps:from_list([{Id, SentUs} || Id <- Ids]),
   ok = gen_tcp:send(Sock, Frames),
   {Parser, LatAcc} = recvBatch(Sock, Parser0, Pending, LatAcc0, 30000),
   benchBatches(Sock, Parser, Tx, NextId,
      Remaining - Count, Concurrency, Path, LatAcc).

makeBatch(0, NextId, Tx, _Path, FramesAcc, IdAcc) ->
   {lists:reverse(FramesAcc), Tx, lists:reverse(IdAcc), NextId};
makeBatch(N, StreamId, Tx0, Path, FramesAcc, IdAcc) ->
   Headers = [
      {<<":method">>, <<"GET">>},
      {<<":scheme">>, <<"http">>},
      {<<":authority">>, <<"127.0.0.1">>},
      {<<":path">>, Path}
   ],
   {Block, Tx} = wsHpack:encode(Headers, Tx0),
   Frame = wsHttp2Frame:headersFrames(Block, StreamId, 16384, true),
   makeBatch(N - 1, StreamId + 2, Tx, Path,
      [Frame | FramesAcc], [StreamId | IdAcc]).

recvBatch(_Sock, Parser, Pending, LatAcc, _Timeout) when map_size(Pending) =:= 0 ->
   {Parser, LatAcc};
recvBatch(Sock, Parser0, Pending0, LatAcc0, Timeout) ->
   {ok, Bin} = gen_tcp:recv(Sock, 0, Timeout),
   {Parser, Frames} = wsHttp2Frame:feed(Parser0, Bin),
   {Pending, LatAcc} = consumeFrames(Frames, Pending0, LatAcc0),
   recvBatch(Sock, Parser, Pending, LatAcc, Timeout).

consumeFrames([], Pending, LatAcc) ->
   {Pending, LatAcc};
consumeFrames([{error, Reason} | _], _Pending, _LatAcc) ->
   erlang:error({http2_frame_error, Reason});
consumeFrames([{frame, rst_stream, _Flags, StreamId, Payload} | Rest], Pending, LatAcc) ->
   case maps:is_key(StreamId, Pending) of
      true -> erlang:error({stream_reset, StreamId, wsHttp2Frame:rstStreamCode(Payload)});
      false -> consumeFrames(Rest, Pending, LatAcc)
   end;
consumeFrames([{frame, Type, Flags, StreamId, _Payload} | Rest], Pending0, LatAcc0) ->
   case (Type =:= headers orelse Type =:= data) andalso
      (Flags band ?END_STREAM =/= 0) andalso maps:find(StreamId, Pending0) of
      {ok, SentUs} ->
         Latency = erlang:monotonic_time(microsecond) - SentUs,
         consumeFrames(Rest, maps:remove(StreamId, Pending0), [Latency | LatAcc0]);
      _ ->
         consumeFrames(Rest, Pending0, LatAcc0)
   end.

avg([]) -> 0;
avg(List) -> lists:sum(List) / length(List).

percentile([], _P) -> 0;
percentile(Sorted, P) ->
   Len = length(Sorted),
   Index = erlang:max(1, erlang:min(Len, trunc((Len - 1) * P) + 1)),
   lists:nth(Index, Sorted).

printResult(R) ->
   io:format(
      "~n=== eWSrv HTTP/2 local benchmark ===~n"
      "requests       : ~p~n"
      "concurrency    : ~p streams~n"
      "connections    : 1~n"
      "warmup         : ~p~n"
      "total          : ~.2f ms~n"
      "throughput     : ~.2f req/s~n"
      "latency avg    : ~.3f ms~n"
      "latency p50    : ~.3f ms~n"
      "latency p95    : ~.3f ms~n"
      "latency p99    : ~.3f ms~n~n",
      [
         maps:get(requests, R),
         maps:get(concurrency, R),
         maps:get(warmup, R),
         maps:get(total_ms, R),
         maps:get(requests_per_sec, R),
         maps:get(latency_avg_ms, R),
         maps:get(latency_p50_ms, R),
         maps:get(latency_p95_ms, R),
         maps:get(latency_p99_ms, R)
      ]).
