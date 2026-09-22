%%%-------------------------------------------------------------------
%%% @doc
%%% HPACK：HTTP/2 头部压缩（RFC 7541）。
%%%
%%% 编解码上下文持有动态表。编码是有状态的（会新增表项），解码必须
%%% 按对端编码时完全相同的字节流、以相同顺序喂入。
%%%
%%% 编码策略（正确性优先于压缩率）：
%%%   - 敏感头部（authorization 等）   -> never-indexed 字面量，不进动态表
%%%   - 静态表或动态表完全命中        -> indexed field（索引字段）
%%%   - 仅名字命中（优先静态表）      -> literal，增量索引（incremental indexing）
%%%   - 其余情况                      -> literal，增量索引
%%%   - 值仅在 Huffman 编码严格更短时才使用 Huffman
%%%
%%% 解码接受 RFC 定义的所有表示形式，包括动态表大小更新和
%%% 永不索引（never-indexed）的字面量。
%%% @end
%%%-------------------------------------------------------------------
-module(wsHpack).

-export([
   new/0
   , new/1
   , encode/2
   , decode/2
   , maxTableSize/1
   , setMax/2
]).

-export_type([ctx/0]).

-define(StaticSize, 61).
-define(DefaultMax, 4096).
-define(EntryOverhead, 32).
%% 单个字符串字面量的长度上限。HPACK 整数最多 5 字节、可声明 2^28，
%% 无上限时恶意头部块能诱导对端缓冲数百 MB（审计 P2 #21）。
%% 1MiB 对真实世界的超长 header（巨型 cookie / JWT）已足够宽裕。
-define(MaxStringLen, 1048576).

%% 动态表：最新条目在最前（index 62 = 表头）。
-record(ctx, {
   dyn = [] :: [{binary(), binary()}],
   size = 0 :: non_neg_integer(),
   max = ?DefaultMax :: pos_integer(),
   %% 编码端专用：对端当前已知的表上限。协议初始值 4096；
   %% setMax 改动上限后，下一个头部块必须先发动态表大小更新
   sentMax = ?DefaultMax :: non_neg_integer(),
   %% 自上次头部块以来，表上限曾经降到的最小值。RFC 7541 §4.2 要求
   %% 先发出这个最小值，再发出最终上限，否则对端不会逐出被缩掉的表项。
   minPending = undefined :: undefined | non_neg_integer()
}).

-opaque ctx() :: #ctx{}.

%%====================================================================
%% 上下文
%%====================================================================

-spec new() -> ctx().
new() -> new(?DefaultMax).

-spec new(non_neg_integer()) -> ctx().
new(Max) when is_integer(Max), Max >= 0 -> #ctx{max = Max}.

-spec maxTableSize(ctx()) -> non_neg_integer().
maxTableSize(#ctx{max = Max}) -> Max.

%% @doc 编码端更新动态表上限，取值来自对端 SETTINGS_HEADER_TABLE_SIZE。
%% 缩小时立即逐出超限表项：对端在收到下一个头部块开头的 size update
%% 后会做同样的逐出，先于块内任何索引引用，两侧表才能保持一致。
%% 随后的 encode/2 会在头部块开头发出对应的大小更新指令（RFC 7541 §4.2）。
-spec setMax(non_neg_integer(), ctx()) -> ctx().
setMax(Max, Ctx = #ctx{max = Max}) ->
   Ctx;
setMax(Max, Ctx = #ctx{dyn = Dyn, size = Size, sentMax = Sent, minPending = Min0})
   when is_integer(Max), Max >= 0, Max =< 16#FFFFFFFF ->
   {Dyn1, Size1} = evict(Dyn, Size, Max),
   Min1 = case Max < Sent of
      true ->
         case Min0 of
            undefined -> Max;
            Old -> erlang:min(Old, Max)
         end;
      false ->
         Min0
   end,
   Ctx#ctx{dyn = Dyn1, size = Size1, max = Max, minPending = Min1}.

%%====================================================================
%% 编码
%%====================================================================

%% @doc 编码一个头部列表，返回线路字节与推进后的上下文。
%% 头部名必须为小写；伪头部（pseudo-header）必须排在普通头部之前
%% （这是调用方的责任，依据 RFC 9113）。
-spec encode([{binary(), binary()}], ctx()) -> {iodata(), ctx()}.
encode(Headers, Ctx0) ->
   {Su, Ctx1} = sizeUpdatePrefix(Ctx0),
   %% 归一化与编码融合成一趟：早先先 comprehension 出一份中间列表，
   %% 每个头部块都要多分配一遍。
   {IoList, Ctx} = lists:mapfoldl(fun(H, C) -> encodeOne(entry(H), C) end, Ctx1, Headers),
   {[Su | IoList], Ctx}.

%% 动态表大小更新（RFC 7541 §4.2）：上限一经 setMax 改动，就必须在
%% 改动之后的第一个头部块开头发出 001xxxxx 指令，否则对端仍按旧上限
%% 逐出表项，索引引用随之错位（COMPRESSION_ERROR）。sentMax 记录对端
%% 已知的上限；对端初始按协议默认 4096 假定（审计 P2 #9）。
sizeUpdatePrefix(Ctx = #ctx{max = Max, sentMax = Sent, minPending = Min0}) ->
   {Updates, Sent1} = case Min0 of
      undefined when Max =:= Sent ->
         {[], Sent};
      undefined ->
         {[prefixByte(5, 1, Max)], Max};
      Min when Min < Sent, Max =/= Min ->
         {[prefixByte(5, 1, Min), prefixByte(5, 1, Max)], Max};
      Min when Min < Sent ->
         {[prefixByte(5, 1, Min)], Max};
      _ when Max =/= Sent ->
         {[prefixByte(5, 1, Max)], Max};
      _ ->
         {[], Sent}
   end,
   {Updates, Ctx#ctx{sentMax = Sent1, minPending = undefined}}.

entry({Name, Value}) -> {lower(Name), toBinary(Value)};
entry(Name) when is_binary(Name) -> {lower(Name), <<>>}.

lower(Bin) -> wsUtil:toLowerStr(Bin).

toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_integer(V) -> integer_to_binary(V);
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) when is_list(V) -> iolist_to_binary(V).


encodeOne({Name, Value}, Ctx) ->
   case sensitive(Name) of
      true ->
         %% 敏感头部（凭据）：never-indexed 字面量（RFC 7541 §6.2.3），
         %% 不进动态表——凭据随动态表在连接上跨请求留存，会放大
         %% CRIME/BREACH 类侧信道的暴露面；RFC 9113 §4.2.3 明确
         %% 点名 authorization / proxy-authorization / cookie /
         %% set-cookie。名字仍引用静态表项以省字节，值永不入表。
         case wsHpackTable:name(Name) of
            Index when is_integer(Index) ->
               {[prefixByte(4, 1, Index), literal(Value)], Ctx};
            none ->
               {[prefixByte(4, 1, 0), literal(Name), literal(Value)], Ctx}
         end;
      false ->
         case findEntry(Name, Value, Ctx) of
            {full, Index} ->
               {[prefixByte(7, 1, Index)], Ctx};
            {name, Index} ->
               {[prefixByte(6, 1, Index), literal(Value)], addDyn(Name, Value, Ctx)};
            none ->
               {[<<0:1, 1:1, 0:6>>, literal(Name), literal(Value)], addDyn(Name, Value, Ctx)}
         end
   end.

%% RFC 9113 §4.2.3 列举的高敏感字段。名字已被 entry/1 归一为小写。
sensitive(<<"authorization">>) -> true;
sensitive(<<"proxy-authorization">>) -> true;
sensitive(<<"cookie">>) -> true;
sensitive(<<"set-cookie">>) -> true;
sensitive(_) -> false.

%% 查找最合适且已存在的表示形式（静态表走配置表子句，O(1)）。
%% 优先级：静态表全命中 > 动态表全命中 > 静态表名命中 > 动态表名命中。
findEntry(Name, Value, #ctx{dyn = Dyn}) ->
   case wsHpackTable:full({Name, Value}) of
      Index when is_integer(Index) -> {full, Index};
      none ->
         %% 动态表只扫一趟，顺带记下首个「仅名字命中」的位置：
         %% 早先全命中与名字命中各扫一遍，未命中时是两次满表遍历。
         case dynLookup(Name, Value, Dyn, 0, none) of
            {full, _} = Full -> Full;
            {name, DynNameIdx} ->
               case wsHpackTable:name(Name) of
                  Index when is_integer(Index) -> {name, Index};
                  none -> {name, DynNameIdx}
               end;
            none ->
               case wsHpackTable:name(Name) of
                  Index when is_integer(Index) -> {name, Index};
                  none -> none
               end
         end
   end.

%% NameHit 记录首个名字命中的索引（动态表按新→旧排列，先遇到的即最新）。
dynLookup(_Name, _Value, [], _K, none) -> none;
dynLookup(_Name, _Value, [], _K, NameHit) -> {name, NameHit};
dynLookup(Name, Value, [{N, V} | Rest], K, NameHit) ->
   case N =:= Name of
      true when V =:= Value -> {full, ?StaticSize + 1 + K};
      true when NameHit =:= none -> dynLookup(Name, Value, Rest, K + 1, ?StaticSize + 1 + K);
      _ -> dynLookup(Name, Value, Rest, K + 1, NameHit)
   end.

%% 生成 HPACK 整数的首字节（RFC 7541 第 5.1 节）：高 (8-PrefixBits) 位
%% 承载表示模式，低 PrefixBits 位是整数的起始部分。仅当前缀全为 1 时，
%% 后面才跟随续传字节。
prefixByte(PrefixBits, Pattern, I) when I < (1 bsl PrefixBits) - 1 ->
   <<Pattern:(8 - PrefixBits), I:PrefixBits>>;
prefixByte(PrefixBits, Pattern, I) ->
   Width = 8 - PrefixBits,
   Max = (1 bsl PrefixBits) - 1,
   integerTail(I - Max, [<<Pattern:Width, Max:PrefixBits>>]).

%% 整数已在前缀里用满（I = 2^N-1）时，剩余值 0 必须再跟一个 0x00
%% 尾字节（RFC 7541 5.1：0x00 表示 "0 个追加"），否则对端会一直等
%% 续传字节而解不出该整数。
integerTail(0, Acc) -> lists:reverse([<<0:8>> | Acc]);
integerTail(I, Acc) when I < 128 ->
   lists:reverse([<<0:1, I:7>> | Acc]);
integerTail(I, Acc) ->
   integerTail(I bsr 7, [<<1:1, (I band 127):7>> | Acc]).

%% 生成 HPACK 字符串字面量（第 5.2 节）。仅当 Huffman 编码更短时才使用。
literal(Bin) ->
   %% encodeSize/1 要逐字节查码长表，只算一次：早先条件与分支里各算一遍。
   HuffSize = wsHuffman:encodeSize(Bin),
   case HuffSize < byte_size(Bin) of
      true ->
         [prefixByte(7, 1, HuffSize), wsHuffman:encode(Bin)];
      false ->
         [prefixByte(7, 0, byte_size(Bin)), Bin]
   end.

%% 加入动态表；超出容量上限时逐出最旧条目。
addDyn(Name, Value, Ctx = #ctx{dyn = Dyn, size = Size, max = Max}) ->
   EntrySize = byte_size(Name) + byte_size(Value) + ?EntryOverhead,
   case EntrySize > Max of
      true -> Ctx#ctx{dyn = [], size = 0};  % 单条目即超容量：清空整张表
      false ->
         Dyn1 = [{Name, Value} | Dyn],
         Size1 = Size + EntrySize,
         {Dyn2, Size2} = evict(Dyn1, Size1, Max),
         Ctx#ctx{dyn = Dyn2, size = Size2}
   end.

evict(Dyn, Size, Max) when Size > Max ->
   %% 只 reverse 一次，再从最旧端连续逐出（避免每条都 reverse）
   evictOldest(lists:reverse(Dyn), Size, Max);
evict(Dyn, Size, _Max) ->
   {Dyn, Size}.

evictOldest(OldestFirst, Size, Max) when Size > Max ->
   [{N, V} | Rest] = OldestFirst,
   evictOldest(Rest, Size - (byte_size(N) + byte_size(V) + ?EntryOverhead), Max);
evictOldest(OldestFirst, Size, _Max) ->
   {lists:reverse(OldestFirst), Size}.

%%====================================================================
%% 解码
%%====================================================================

%% @doc 解码一个完整的头部块片段。CONTINUATION 帧必须先由调用方拼接
%% 到一起再传入。
-spec decode(binary(), ctx()) -> {ok, [{binary(), binary()}], ctx()} | {error, term()}.
decode(Bin, Ctx) ->
   %% AllowSizeUpdate=true：RFC 7541 §4.2 要求 dynamic table size update
   %% 只能出现在头部块开头（连续多个 size update 亦可）。
   case decodeLoop(Bin, Ctx, [], true) of
      {ok, Rest, Ctx1, Headers} when Rest =:= <<>> ->
         {ok, lists:reverse(Headers), Ctx1};
      {ok, _Rest, _Ctx1, _Headers} ->
         {error, trailingBytes};
      {error, _} = E -> E
   end.

decodeLoop(<<>>, Ctx, Acc, _AllowSU) -> {ok, <<>>, Ctx, Acc};
decodeLoop(Bin, Ctx, Acc, AllowSU) ->
   case Bin of
      %% indexed header field（索引头部字段）
      <<1:1, Rest/bits>> ->
         case takeInteger(7, Rest) of
            {ok, 0, _} -> {error, badIndex};
            {ok, Index, Rest1} ->
               case lookupIndex(Index, Ctx) of
                  {ok, N, V} -> decodeLoop(Rest1, Ctx, [{N, V} | Acc], false);
                  error -> {error, {badIndex, Index}}
               end;
            more -> {error, incomplete};
            {error, R} -> {error, R}
         end;
      %% literal with incremental indexing（带增量索引的字面量）
      <<0:1, 1:1, Rest/bits>> ->
         literalIndexed(6, Rest, fun addDyn/3, Ctx, Acc);
      %% literal without indexing（不索引的字面量）
      <<0:1, 0:1, 0:1, 0:1, Rest/bits>> ->
         literalIndexed(4, Rest, fun(_N, _V, C) -> C end, Ctx, Acc);
      %% literal never indexed（永不索引的字面量）
      <<0:1, 0:1, 0:1, 1:1, Rest/bits>> ->
         literalIndexed(4, Rest, fun(_N, _V, C) -> C end, Ctx, Acc);
      %% dynamic table size update（动态表大小更新）
      <<0:1, 0:1, 1:1, Rest/bits>> ->
         case AllowSU of
            false ->
               %% 块内非开头位置出现 size update → 压缩错误
               {error, sizeUpdateNotAtStart};
            true ->
               case takeInteger(5, Rest) of
                  {ok, NewMax, Rest1} when NewMax =< Ctx#ctx.max ->
                     Ctx1 = resize(NewMax, Ctx),
                     %% 开头可连续多个 size update
                     decodeLoop(Rest1, Ctx1, Acc, true);
                  {ok, Bad, _} -> {error, {badTableSize, Bad}};
                  more -> {error, incomplete};
                  {error, R} -> {error, R}
               end
         end
   end.

%% 名字本身也可能是指针的字面量（四种字面量表示都用它；
%% `Update' 决定该条目是否加入动态表）。
literalIndexed(PrefixBits, Bin, Update, Ctx, Acc) ->
   case takeInteger(PrefixBits, Bin) of
      {ok, 0, Rest} ->
         case takeString(Rest) of
            {ok, Name, Rest1} ->
               literalValue(Name, Rest1, Update, Ctx, Acc);
            more -> {error, incomplete};
            {error, R} -> {error, R}
         end;
      {ok, Index, Rest} ->
         case lookupIndex(Index, Ctx) of
            {ok, Name, _} ->
               literalValue(Name, Rest, Update, Ctx, Acc);
            error -> {error, {badIndex, Index}}
         end;
      more -> {error, incomplete};
      {error, R} -> {error, R}
   end.

literalValue(Name, Bin, Update, Ctx, Acc) ->
   case takeString(Bin) of
      {ok, Value, Rest} ->
         %% 已产出字段：此后禁止 size update
         decodeLoop(Rest, Update(Name, Value, Ctx), [{Name, Value} | Acc], false);
      more -> {error, incomplete};
      {error, R} -> {error, R}
   end.

lookupIndex(Index, _Ctx) when Index =< 0 -> error;
lookupIndex(Index, _Ctx) when Index =< ?StaticSize ->
   case wsHpackTable:get(Index) of
      {N, V} -> {ok, N, V};
      error -> error
   end;
lookupIndex(Index, #ctx{dyn = Dyn}) ->
   %% 单趟定位：早先先 length/1 再 lists:nth/2，越界检查白走一遍整表，
   %% 而这是解码侧每个索引字段都要执行的路径。
   dynNth(Index - ?StaticSize, Dyn).

dynNth(1, [{N, V} | _]) -> {ok, N, V};
dynNth(K, [_ | Rest]) when K > 1 -> dynNth(K - 1, Rest);
dynNth(_K, _Dyn) -> error.

resize(NewMax, Ctx = #ctx{dyn = Dyn, size = Size}) ->
   Ctx1 = Ctx#ctx{max = NewMax},
   case Size > NewMax of
      true ->
         {Dyn1, Size1} = evict(Dyn, Size, NewMax),
         Ctx1#ctx{dyn = Dyn1, size = Size1};
      false ->
         Ctx1
   end.

%% 解析一个带 N 位前缀的 HPACK 整数。`more' 表示需要更多字节。
%% 输入可能不是按位对齐的（前缀模式位随表示形式而变化）。
takeInteger(PrefixBits, Bin) ->
   Full = (1 bsl PrefixBits) - 1,
   case Bin of
      <<Prefix:PrefixBits, Rest/bits>> when Prefix < Full ->
         {ok, Prefix, Rest};
      <<Full:PrefixBits, Rest/bits>> ->
         takeIntegerTail(Rest, 0, Full);
      _ ->
         more
   end.

%% RFC 7541 §5.1：整数编码总长不得超过 5 个 octet（含前缀字节），
%% 即续传字节最多 4 个。M 为已读续传字节数。
takeIntegerTail(<<>>, _, _) -> more;
takeIntegerTail(_Bin, M, _Acc) when M >= 4 ->
   {error, integerTooLong};
takeIntegerTail(<<1:1, V:7, Rest/bits>>, M, Acc) ->
   takeIntegerTail(Rest, M + 1, Acc + (V bsl (7 * M)));
takeIntegerTail(<<0:1, V:7, Rest/bits>>, M, Acc) ->
   {ok, Acc + (V bsl (7 * M)), Rest}.

%% 解析一个 HPACK 字符串字面量。`more' 表示需要更多字节。
%% 声明长度超过 ?MaxStringLen 直接报错，绝不为等齐一个（可能永远
%% 不会到达的）超大字面量而无界缓冲（审计 P2 #21）。
takeString(<<H:1, Rest/bits>>) ->
   case takeInteger(7, Rest) of
      {ok, Len, Rest1} when Len =< ?MaxStringLen ->
         case Rest1 of
            <<Str:Len/binary, Rest2/bits>> when H =:= 0 ->
               {ok, Str, Rest2};
            <<Str:Len/binary, Rest2/bits>> when H =:= 1 ->
               %% wsHuffman:decode 直接返回二进制，并在输入非法时抛异常。
               try
                  {ok, wsHuffman:decode(Str), Rest2}
               catch
                  _:_ -> {error, badHuffman}
               end;
            _ ->
               more
         end;
      {ok, Len, _} when Len > ?MaxStringLen ->
         {error, stringTooLong};
      more -> more;
      {error, R} -> {error, R}
   end;
takeString(_) ->
   more.
