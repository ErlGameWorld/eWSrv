-module(wsHttp1Bench).

-export([run/0, run/1]).

%% @doc 本机 HTTP/1.1 keep-alive benchmark。
%%
%% 与 wsHttp2Bench 的对比口径：
%%   HTTP/1.1: concurrency 条 keep-alive TCP connection，每条连接同一时刻1个请求
%%   HTTP/2  : 1条 TCP connection，concurrency 个并发 stream
%%
%% 使用:
%%   rebar3 as test shell
%%   1> wsHttp1Bench:run().
%%   2> wsHttp1Bench:run(#{requests => 50000, concurrency => 32}).
run() ->
   run(#{requests => 10000, concurrency => 32, warmup => 1000, path => <<"/one">>, quiet => false}).

run(Opts) when is_map(Opts) ->
   Requests = positive(maps:get(requests, Opts, 10000), requests),
   Concurrency0 = positive(maps:get(concurrency, Opts, 32), concurrency),
   Concurrency = erlang:min(100, Concurrency0),
   Warmup = nonNegative(maps:get(warmup, Opts, 1000), warmup),
   Path = maps:get(path, Opts, <<"/one">>),
   Quiet = maps:get(quiet, Opts, false),

   {ok, _} = application:ensure_all_started(eWSrv),
   Name = ws_http1_bench,
   _ = catch eWSrv:closeSrv(Name),
   try
      {ok, _} = eWSrv:openSrv(Name, 0, [{http2, false}, {wsMod, wsHttp2TestHandler}, {keepAliveTimeout, 300000}]),
      ListenerName = ntCom:lsName(tcp, Name),
      Port = ntTcpListener:getListenPort(ListenerName),

      %% 先建立连接并预热，再开始计时；避免连接建立/模块首次加载污染结果。
      Workers = startWorkers(Concurrency, Port, Path),
      warmup(Workers, Warmup),

      StartUs = erlang:monotonic_time(microsecond),
      LatUs = measuredRun(Workers, Requests),
      TotalUs = erlang:monotonic_time(microsecond) - StartUs,
      stopWorkers(Workers),

      Sorted = lists:sort(LatUs),
      Result = result(Requests, Concurrency, Warmup, TotalUs, Sorted),
      Quiet orelse printResult(Result),
      Result
   after
      _ = catch eWSrv:closeSrv(Name)
   end.

startWorkers(Count, Port, Path) ->
   Parent = self(),
   Workers = [
      spawn_link(fun() -> workerInit(Parent, Port, Path) end)
      || _ <- lists:seq(1, Count)
   ],
   waitReady(Workers),
   Workers.

waitReady([]) ->
   ok;
waitReady(Workers) ->
   receive
      {http1_bench_ready, Pid} ->
         waitReady(lists:delete(Pid, Workers));
      {http1_bench_error, Pid, Reason} ->
         exit({worker_start_failed, Pid, Reason})
   after 10000 ->
      exit({worker_start_timeout, Workers})
   end.

workerInit(Parent, Port, Path) ->
   case gen_tcp:connect({127,0,0,1}, Port, [binary, {packet, raw}, {active, false}, {nodelay, true}], 5000) of
      {ok, Sock} ->
         Parent ! {http1_bench_ready, self()},
         Request = request(Path),
         workerLoop(Sock, Request, <<>>);
      {error, Reason} ->
         Parent ! {http1_bench_error, self(), Reason}
   end.

workerLoop(Sock, Request, Buffer0) ->
   receive
      {run, From, Ref, Count, Measure} ->
         case runRequests(Sock, Request, Buffer0, Count, Measure, []) of
            {ok, Buffer, Latencies} ->
               From ! {Ref, self(), Latencies},
               workerLoop(Sock, Request, Buffer);
            {error, Reason} ->
               From ! {Ref, self(), {error, Reason}},
               catch gen_tcp:close(Sock),
               exit(Reason)
         end;
      stop ->
         catch gen_tcp:close(Sock),
         ok
   end.

request(Path) ->
   [
      <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
      <<"Host: 127.0.0.1\r\n">>,
      <<"Connection: keep-alive\r\n">>,
      <<"Accept: */*\r\n">>,
      <<"\r\n">>
   ].

runRequests(_Sock, _Request, Buffer, 0, _Measure, Acc) ->
   {ok, Buffer, lists:reverse(Acc)};
runRequests(Sock, Request, Buffer0, N, Measure, Acc) ->
   T0 = erlang:monotonic_time(microsecond),
   case gen_tcp:send(Sock, Request) of
      ok ->
         case recvResponse(Sock, Buffer0, 30000) of
            {ok, 200, _Headers, _Body, Buffer} ->
               Acc1 =
                  case Measure of
                     true -> [erlang:monotonic_time(microsecond) - T0 | Acc];
                     false -> Acc
                  end,
               runRequests(Sock, Request, Buffer, N - 1, Measure, Acc1);
            {ok, Status, _Headers, _Body, _Buffer} ->
               {error, {unexpected_status, Status}};
            {error, _} = Error ->
               Error
         end;
      {error, _} = Error ->
         Error
   end.

%% 支持响应与下一响应黏包；benchmark 每连接仅1个in-flight，
%% 因此无需处理HTTP/1.1 pipeline的响应排序。
recvResponse(Sock, Buffer0, Timeout) ->
   case splitHeaders(Buffer0) of
      more ->
         case gen_tcp:recv(Sock, 0, Timeout) of
            {ok, Bin} -> recvResponse(Sock, <<Buffer0/binary, Bin/binary>>, Timeout);
            {error, _} = Error -> Error
         end;
      {ok, Head, Rest} ->
         case parseHead(Head) of
            {ok, Status, Headers, Length} ->
               recvBody(Sock, Status, Headers, Length, Rest, Timeout);
            {error, _} = Error ->
               Error
         end
   end.

splitHeaders(Bin) ->
   case binary:match(Bin, <<"\r\n\r\n">>) of
      nomatch ->
         more;
      {Pos, 4} ->
         <<Head:Pos/binary, "\r\n\r\n", Rest/binary>> = Bin,
         {ok, Head, Rest}
   end.

parseHead(Head) ->
   case binary:split(Head, <<"\r\n">>, [global]) of
      [StatusLine | HeaderLines] ->
         case binary:split(StatusLine, <<" ">>, [global]) of
            [_Version, StatusBin | _] ->
               try binary_to_integer(StatusBin) of
                  Status ->
                     Headers = [parseHeader(Line) || Line <- HeaderLines, Line =/= <<>>],
                     case contentLength(Headers) of
                        {ok, Length} -> {ok, Status, Headers, Length};
                        Error -> Error
                     end
               catch
                  _:_ -> {error, bad_status_line}
               end;
            _ ->
               {error, bad_status_line}
         end;
      _ ->
         {error, bad_response}
   end.

parseHeader(Line) ->
   case binary:match(Line, <<":">>) of
      {Pos, 1} ->
         <<Name:Pos/binary, ":", Value0/binary>> = Line,
         {lower(Name), trim(Value0)};
      nomatch ->
         {<<>>, <<>>}
   end.

contentLength(Headers) ->
   case lists:keyfind(<<"content-length">>, 1, Headers) of
      {_, Value} ->
         try binary_to_integer(Value) of
            N when N >= 0 -> {ok, N};
            _ -> {error, bad_content_length}
         catch
            _:_ -> {error, bad_content_length}
         end;
      false ->
         {error, missing_content_length}
   end.

recvBody(_Sock, Status, Headers, Length, Rest, _Timeout)
   when byte_size(Rest) >= Length ->
   <<Body:Length/binary, Tail/binary>> = Rest,
   {ok, Status, Headers, Body, Tail};
recvBody(Sock, Status, Headers, Length, Rest, Timeout) ->
   case gen_tcp:recv(Sock, 0, Timeout) of
      {ok, Bin} ->
         recvBody(Sock, Status, Headers, Length, <<Rest/binary, Bin/binary>>, Timeout);
      {error, _} = Error ->
         Error
   end.

warmup(_Workers, 0) ->
   ok;
warmup(Workers, Count) ->
   _ = runDistributed(Workers, Count, false),
   ok.

measuredRun(Workers, Count) ->
   lists:append(runDistributed(Workers, Count, true)).

runDistributed(Workers, Count, Measure) ->
   Dist = distribute(Count, length(Workers)),
   Ref = make_ref(),
   Active = [
      begin
         Pid ! {run, self(), Ref, N, Measure},
         Pid
      end
      || {Pid, N} <- lists:zip(Workers, Dist), N > 0
   ],
   collect(Ref, Active, []).

collect(_Ref, [], Acc) ->
   Acc;
collect(Ref, Workers, Acc) ->
   receive
      {Ref, Pid, {error, Reason}} ->
         exit({http1_bench_worker_failed, Pid, Reason});
      {Ref, Pid, Latencies} ->
         collect(Ref, lists:delete(Pid, Workers), [Latencies | Acc])
   after 60000 ->
      exit({http1_bench_timeout, Workers})
   end.

distribute(Total, N) ->
   Base = Total div N,
   Extra = Total rem N,
   [Base + case I =< Extra of true -> 1; false -> 0 end || I <- lists:seq(1, N)].

stopWorkers(Workers) ->
   [Pid ! stop || Pid <- Workers],
   ok.

result(Requests, Concurrency, Warmup, TotalUs, Sorted) ->
   #{
      protocol => http1,
      requests => Requests,
      concurrency => Concurrency,
      connections => Concurrency,
      warmup => Warmup,
      total_ms => TotalUs / 1000,
      requests_per_sec => Requests * 1000000 / erlang:max(1, TotalUs),
      latency_avg_ms => avg(Sorted) / 1000,
      latency_p50_ms => percentile(Sorted, 0.50) / 1000,
      latency_p95_ms => percentile(Sorted, 0.95) / 1000,
      latency_p99_ms => percentile(Sorted, 0.99) / 1000
   }.

avg([]) ->
   0;
avg(List) ->
   lists:sum(List) / length(List).

percentile([], _P) ->
   0;
percentile(Sorted, P) ->
   Len = length(Sorted),
   Index = erlang:max(1, erlang:min(Len, trunc((Len - 1) * P) + 1)),
   lists:nth(Index, Sorted).

printResult(R) ->
   io:format(
      "~n=== eWSrv HTTP/1.1 local benchmark ===~n"
      "requests       : ~p~n"
      "connections    : ~p keep-alive~n"
      "warmup         : ~p~n"
      "total          : ~.2f ms~n"
      "throughput     : ~.2f req/s~n"
      "latency avg    : ~.3f ms~n"
      "latency p50    : ~.3f ms~n"
      "latency p95    : ~.3f ms~n"
      "latency p99    : ~.3f ms~n~n",
      [
         maps:get(requests, R),
         maps:get(connections, R),
         maps:get(warmup, R),
         maps:get(total_ms, R),
         maps:get(requests_per_sec, R),
         maps:get(latency_avg_ms, R),
         maps:get(latency_p50_ms, R),
         maps:get(latency_p95_ms, R),
         maps:get(latency_p99_ms, R)
      ]).

positive(N, _Name) when is_integer(N), N > 0 ->
   N;
positive(_N, Name) ->
   error({bad_option, Name}).

nonNegative(N, _Name) when is_integer(N), N >= 0 ->
   N;
nonNegative(_N, Name) ->
   error({bad_option, Name}).

lower(Bin) ->
   <<<<(lowerByte(C))>> || <<C>> <= Bin>>.

lowerByte(C) when C >= $A, C =< $Z ->
   C + 32;
lowerByte(C) ->
   C.

trim(Bin) ->
   string:trim(Bin).
