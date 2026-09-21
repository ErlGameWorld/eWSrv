-module(wsBenchSmokeTests).

-include_lib("eunit/include/eunit.hrl").

http1_benchmark_smoke_test_() ->
   {timeout, 20, fun() ->
      R = wsHttp1Bench:run(#{
         requests => 32,
         concurrency => 4,
         warmup => 8,
         path => <<"/one">>,
         quiet => true
      }),
      ?assertEqual(http1, maps:get(protocol, R)),
      ?assertEqual(32, maps:get(requests, R)),
      ?assertEqual(4, maps:get(connections, R)),
      ?assert(maps:get(requests_per_sec, R) > 0),
      ?assert(maps:get(latency_p95_ms, R) >= 0)
   end}.
