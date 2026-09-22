-module(wsHttpBench).

-export([
   compare/0
   , compare/1
   , matrix/0
   , matrix/1
]).

%% @doc 使用完全相同的请求数、并发度、warm-up 和 handler/path
%% 连续运行 HTTP/1.1 与 HTTP/2 benchmark。
%%
%% H1 concurrency=N 表示 N 条 keep-alive connection。
%% H2 concurrency=N 表示 1 条 connection 上 N 个并发 stream。
compare() ->
   compare(#{requests => 10000, concurrency => 32, warmup => 1000, path => <<"/one">>}).

compare(Opts0) when is_map(Opts0) ->
   Requests = maps:get(requests, Opts0, 10000),
   Concurrency = maps:get(concurrency, Opts0, 32),
   Warmup = maps:get(warmup, Opts0, 1000),
   Path = maps:get(path, Opts0, <<"/one">>),
   Opts = #{requests => Requests, concurrency => Concurrency, warmup => Warmup, path => Path, quiet => true},
   H1 = wsHttp1Bench:run(Opts),
   H2 = wsHttp2Bench:run(Opts),
   H1Rps = maps:get(requests_per_sec, H1),
   H2Rps = maps:get(requests_per_sec, H2),
   Result = #{
      requests => Requests,
      concurrency => Concurrency,
      warmup => Warmup,
      path => Path,
      http1 => H1,
      http2 => H2,
      h2_over_h1_throughput => safeRatio(H2Rps, H1Rps),
      h1_over_h2_p50_latency => safeRatio(maps:get(latency_p50_ms, H1), maps:get(latency_p50_ms, H2)),
      h1_over_h2_p95_latency => safeRatio(maps:get(latency_p95_ms, H1), maps:get(latency_p95_ms, H2))
   },
   printCompare(Result),
   Result.

%% @doc 跑一组典型并发度，观察 H1 connection pool 与 H2 multiplexing 的扩展曲线。
matrix() ->
   matrix(#{requests => 10000, warmup => 1000, path => <<"/one">>, concurrencies => [1, 8, 16, 32, 64]}).

matrix(Opts) when is_map(Opts) ->
   Concurrencies = maps:get(concurrencies, Opts, [1, 8, 16, 32, 64]),
   Base = maps:remove(concurrencies, Opts),
   io:format(
      "~n=== eWSrv HTTP/1.1 vs HTTP/2 benchmark matrix ===~n"
      " concurrency | H1 req/s | H2 req/s | H2/H1 | H1 p95 ms | H2 p95 ms~n"
      "-------------+----------+----------+-------+-----------+----------~n"),
   Results = [matrixOne(C, Base) || C <- Concurrencies],
   io:format("~n"),
   Results.

matrixOne(Concurrency, Base) ->
   Requests = maps:get(requests, Base, 10000),
   Warmup = maps:get(warmup, Base, 1000),
   Path = maps:get(path, Base, <<"/one">>),
   Opts = #{requests => Requests, concurrency => Concurrency, warmup => Warmup, path => Path, quiet => true},
   H1 = wsHttp1Bench:run(Opts),
   H2 = wsHttp2Bench:run(Opts),
   H1Rps = maps:get(requests_per_sec, H1),
   H2Rps = maps:get(requests_per_sec, H2),
   Ratio = safeRatio(H2Rps, H1Rps),
   io:format(" ~11B | ~8.1f | ~8.1f | ~6.2fx | ~9.3f | ~8.3f~n", [
      Concurrency,
      float(H1Rps), float(H2Rps), float(Ratio),
      float(maps:get(latency_p95_ms, H1)),
      float(maps:get(latency_p95_ms, H2))
   ]),
   #{concurrency => Concurrency, http1 => H1, http2 => H2, h2_over_h1_throughput => Ratio}.

safeRatio(_A, 0) ->
   0.0;
safeRatio(A, B) ->
   A / B.

printCompare(#{http1 := H1, http2 := H2} = R) ->
   io:format(
      "~n=== eWSrv HTTP/1.1 vs HTTP/2 ===~n"
      "requests       : ~p~n"
      "concurrency    : ~p~n"
      "warmup         : ~p~n"
      "path           : ~s~n"
      "~n"
      "metric          HTTP/1.1              HTTP/2~n"
      "--------------  --------------------  --------------------~n"
      "connections     ~20B  ~20B~n"
      "parallelism     ~20B  ~20B~n"
      "req/s           ~20.2f  ~20.2f~n"
      "avg ms          ~20.3f  ~20.3f~n"
      "p50 ms          ~20.3f  ~20.3f~n"
      "p95 ms          ~20.3f  ~20.3f~n"
      "p99 ms          ~20.3f  ~20.3f~n"
      "~nH2/H1 throughput: ~.3fx~n~n",
      [
         maps:get(requests, R),
         maps:get(concurrency, R),
         maps:get(warmup, R),
         maps:get(path, R),
         maps:get(connections, H1), maps:get(connections, H2),
         maps:get(concurrency, H1), maps:get(concurrency, H2),
         maps:get(requests_per_sec, H1), maps:get(requests_per_sec, H2),
         maps:get(latency_avg_ms, H1), maps:get(latency_avg_ms, H2),
         maps:get(latency_p50_ms, H1), maps:get(latency_p50_ms, H2),
         maps:get(latency_p95_ms, H1), maps:get(latency_p95_ms, H2),
         maps:get(latency_p99_ms, H1), maps:get(latency_p99_ms, H2),
         maps:get(h2_over_h1_throughput, R)
      ]).
