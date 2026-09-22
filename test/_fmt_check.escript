#!/usr/bin/env escript
-mode(compile).
main(_) ->
   io:format(" ~11B | ~8.0f | ~8.0f | ~5.2f~c | ~9.3f | ~8.3f~n",
      [1, 2916.07, 2394.59, 0.8211713579, $x, 0.41, 0.614]),
   ok.
