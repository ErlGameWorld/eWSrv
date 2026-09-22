#!/usr/bin/env escript
%% 对照 eWSrv 里两种真实累加：
%% 1. body 放在 map/record 里，每个 TCP/DATA 片段都 match 出来再写回
%% 2. WebSocket unmask 的尾递归，Acc 只出现在 <<Acc/binary, _/binary>> 左侧
-mode(compile).

main(_) ->
    io:format("otp ~s~n", [erlang:system_info(otp_release)]),
    io:format("~n== body in map (HTTP/1 bodyAcc / HTTP/2 body_acc) ==~n"),
    io:format("~-22s ~-14s ~-14s ~-10s~n", ["case", "bin+match", "list+reverse", "winner"]),
    body_case("256KB / MTU", 256 * 1024, 1460, 30),
    body_case("1MB / 16KB", 1024 * 1024, 16384, 20),
    body_case("4MB / 16KB", 4 * 1024 * 1024, 16384, 8),
    body_case("8MB / 16KB", 8 * 1024 * 1024, 16384, 4),
    body_case("64KB / 8B", 64 * 1024, 8, 10),
    io:format("~n== websocket unmask (tail recursion, 4 bytes each step) ==~n"),
    io:format("~-22s ~-14s ~-14s ~-10s~n", ["case", "bin append", "list+reverse", "winner"]),
    unmask_case("64KB", 64 * 1024, 20),
    unmask_case("256KB", 256 * 1024, 10),
    unmask_case("1MB", 1024 * 1024, 5),
    ok.

body_case(Name, Total, Chunk, Reps) ->
    Chunks = chunks(Total, Chunk),
    Check = iolist_to_binary(Chunks),
    {BinUs, BinOut} = repeat(Reps, fun() -> body_bin(Chunks) end),
    {ListUs, ListOut} = repeat(Reps, fun() -> body_list(Chunks) end),
    true = BinOut =:= Check,
    true = ListOut =:= Check,
    io:format("~-22s ~-14s ~-14s ~-10s~n", [
        Name, fmt(BinUs), fmt(ListUs), winner(BinUs, ListUs, "bin", "list")
    ]).

unmask_case(Name, Size, Reps) ->
    Data = binary:copy(<<16#5a>>, Size),
    Mask = <<1, 2, 3, 4>>,
    {BinUs, BinOut} = repeat(Reps, fun() -> unmask_bin(Data, Mask) end),
    {ListUs, ListOut} = repeat(Reps, fun() -> unmask_list(Data, Mask) end),
    true = BinOut =:= ListOut,
    io:format("~-22s ~-14s ~-14s ~-10s~n", [
        Name, fmt(BinUs), fmt(ListUs), winner(BinUs, ListUs, "bin", "list")
    ]).

%% 模拟 parseFixedBody / applyData：从状态里取出累加器，写回状态。
%% 这一下 match 会让 <<Acc/binary, Chunk/binary>> 失去原地扩容。
body_bin(Chunks) ->
    maps:get(bin, lists:foldl(fun(Chunk, #{bin := Bin, size := Size}) ->
        #{bin => <<Bin/binary, Chunk/binary>>, size => Size + byte_size(Chunk)}
    end, #{bin => <<>>, size => 0}, Chunks)).

body_list(Chunks) ->
    #{acc := Acc} = lists:foldl(fun(Chunk, #{acc := Acc, size := Size}) ->
        #{acc => [Chunk | Acc], size => Size + byte_size(Chunk)}
    end, #{acc => [], size => 0}, Chunks),
    iolist_to_binary(lists:reverse(Acc)).

%% 旧 unmask：尾递归，Acc 从不被 match，只往后面接 4 字节。
unmask_bin(Data, <<M0:8, M1:8, M2:8, M3:8>>) ->
    unmask_bin(Data, M0, M1, M2, M3, 0, byte_size(Data), <<>>).

unmask_bin(<<>>, _, _, _, _, _, _, Acc) ->
    Acc;
unmask_bin(Data, M0, M1, M2, M3, Index, Remaining, Acc) when Remaining >= 4 ->
    <<A:8, B:8, C:8, D:8, Rest/binary>> = Data,
    Unmasked = <<(A bxor mask(Index, M0, M1, M2, M3)):8,
                 (B bxor mask(Index + 1, M0, M1, M2, M3)):8,
                 (C bxor mask(Index + 2, M0, M1, M2, M3)):8,
                 (D bxor mask(Index + 3, M0, M1, M2, M3)):8>>,
    unmask_bin(Rest, M0, M1, M2, M3, Index + 4, Remaining - 4, <<Acc/binary, Unmasked/binary>>);
unmask_bin(<<Byte:8, Rest/binary>>, M0, M1, M2, M3, Index, Remaining, Acc) ->
    Unmasked = Byte bxor mask(Index, M0, M1, M2, M3),
    unmask_bin(Rest, M0, M1, M2, M3, Index + 1, Remaining - 1, <<Acc/binary, Unmasked:8>>).

%% 现在的 unmask：每 4 字节造一个小 binary，头插，最后 reverse。
unmask_list(Data, <<M0:8, M1:8, M2:8, M3:8>>) ->
    unmask_list(Data, M0, M1, M2, M3, 0, []).

unmask_list(<<A:8, B:8, C:8, D:8, Rest/binary>>, M0, M1, M2, M3, Index, Acc) ->
    Chunk = <<(A bxor mask(Index, M0, M1, M2, M3)):8,
              (B bxor mask(Index + 1, M0, M1, M2, M3)):8,
              (C bxor mask(Index + 2, M0, M1, M2, M3)):8,
              (D bxor mask(Index + 3, M0, M1, M2, M3)):8>>,
    unmask_list(Rest, M0, M1, M2, M3, Index + 4, [Chunk | Acc]);
unmask_list(<<Byte:8, Rest/binary>>, M0, M1, M2, M3, Index, Acc) ->
    Chunk = <<(Byte bxor mask(Index, M0, M1, M2, M3)):8>>,
    unmask_list(Rest, M0, M1, M2, M3, Index + 1, [Chunk | Acc]);
unmask_list(<<>>, _, _, _, _, _, Acc) ->
    iolist_to_binary(lists:reverse(Acc)).

mask(Index, M0, _, _, _) when Index band 3 =:= 0 -> M0;
mask(Index, _, M1, _, _) when Index band 3 =:= 1 -> M1;
mask(Index, _, _, M2, _) when Index band 3 =:= 2 -> M2;
mask(_, _, _, _, M3) -> M3.

chunks(Total, Chunk) ->
    chunks(Total, Chunk, []).

chunks(0, _Chunk, Acc) ->
    lists:reverse(Acc);
chunks(Left, Chunk, Acc) when Left > Chunk ->
    chunks(Left - Chunk, Chunk, [binary:copy(<<$x>>, Chunk) | Acc]);
chunks(Left, _Chunk, Acc) ->
    lists:reverse([binary:copy(<<$x>>, Left) | Acc]).

repeat(Reps, Fun) ->
    _ = Fun(),
    {Us, Last} = lists:foldl(fun(_, {Sum, _}) ->
        {T, V} = timer:tc(Fun),
        {Sum + T, V}
    end, {0, undefined}, lists:seq(1, Reps)),
    {Us div Reps, Last}.

fmt(Us) ->
    io_lib:format("~.2f ms", [Us / 1000]).

winner(A, B, _NameA, _NameB) when A * 100 =< B * 110, B * 100 =< A * 110 ->
    "tie";
winner(A, B, NameA, _NameB) when A < B ->
    NameA;
winner(_, _, _, NameB) ->
    NameB.
