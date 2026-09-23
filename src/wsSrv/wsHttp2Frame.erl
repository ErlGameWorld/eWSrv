%%%-------------------------------------------------------------------
%%% @doc
%%% HTTP/2 线路格式（RFC 9113 / RFC 7540）的 frame 编解码器，
%%% 本模块只做“字节 <-> frame”的纯函数转换。
%%%
%%% 职责边界：socket、stream 状态机与 flow control 决策都归连接进程
%%% wsHttp2；本模块把 frame 编成字节、把字节解成 frame，不做任何 IO，
%%% 也不维护连接状态（parser 只缓存不足一帧的字节）。DATA/HEADERS/
%%% CONTINUATION 的负载原样透传——HPACK 在 wsHpack，stream 语义在
%%% wsHttp2。
%%%
%%% frame 头布局（RFC 9113 4.1）：
%%%
%%%   Length (24) | Type (8) | Flags (8) | R (1) | Stream Identifier (31)
%%%
%%% 解码是增量的：feed/2 返回已解出的完整 frame 以及未消费的字节前缀，
%%% 与 wsHttpProtocol 的解析器契约一致，便于上层统一按“喂字节、取事件”驱动。
%%% @end
%%%-------------------------------------------------------------------
-module(wsHttp2Frame).

-export([
   new/0
   , feed/2
   , setMaxFrame/2
   , frame/3
   , frame/4
   , settingsFrame/1
   , settingsDecode/1
   , ackFrame/0
   , pingFrame/1
   , pongFrame/1
   , goawayFrame/2
   , windowUpdateFrame/2
   , rstStreamFrame/2
   , headersFrames/3
   , headersFrames/4
   , dataFrames/3
   , splitPayload/2
   , goawayFields/1
   , pingData/1
   , windowUpdateIncrement/1
   , rstStreamCode/1
   , priorityFields/1
]).

-export_type([
   parser/0
   , frame/0
   , frame_type/0
]).

%%====================================================================
%% 常量
%%====================================================================

%% frame 类型编号（RFC 9113 第 6 节 / RFC 7540 11.2 的注册表）。
%% DATA：承载请求或响应体
-define(DATA, 0).
%% HEADERS：承载 HPACK 压缩后的 header 块（放不下时用 CONTINUATION 续传）
-define(HEADERS, 1).
%% PRIORITY：声明 stream 依赖关系与权重
-define(PRIORITY, 2).
%% RST_STREAM：立即终止一条 stream
-define(RST_STREAM, 3).
%% SETTINGS：连接级参数协商（流控窗口、并发上限等）
-define(SETTINGS, 4).
%% PUSH_PROMISE：服务端推送预告（本客户端不发起推送）
-define(PUSH_PROMISE, 5).
%% PING：保活与 RTT 测量，8 字节不透明数据
-define(PING, 6).
%% GOAWAY：优雅关闭连接，并告知最后处理的 stream id
-define(GOAWAY, 7).
%% WINDOW_UPDATE：flow control 窗口增量（stream id 为 0 表示连接级）
-define(WINDOW_UPDATE, 8).
%% CONTINUATION：HEADERS 之后的 header 块续帧，保证头部块严格有序
-define(CONTINUATION, 9).

%% flag 位：同一个 8 位字段由各 frame 类型自行解释，故按语义分别命名。
%% END_STREAM：DATA/HEADERS，表示本 stream 的消息结束（半关闭）
-define(FLAG_END_STREAM, 16#01).
%% ACK：SETTINGS/PING 的确认帧（与 END_STREAM 同为 0x01）
-define(FLAG_ACK, 16#01).
%% END_HEADERS：HEADERS/CONTINUATION，表示 header 块到此结束
-define(FLAG_END_HEADERS, 16#04).
%% PADDED：DATA/HEADERS，负载首字节为填充长度
-define(FLAG_PADDED, 16#08).
%% PRIORITY：HEADERS，负载开头带 5 字节的 PRIORITY 字段
-define(FLAG_PRIORITY, 16#20).

%% SETTINGS_MAX_FRAME_SIZE 的协议默认值（RFC 9113 6.5.2）：既是我们发送
%% 时的默认上限，也是收到对端 SETTINGS 之前对端发来的 frame 所能容忍的
%% 最大负载——对端不得在收到我们的 SETTINGS 前超出此值。
-define(DEFAULT_MAX_FRAME, 16384).

%% frame 类型：unknown 用于透传对端自定义的扩展类型，避免解析时崩溃。
-type frame_type() :: data | headers | priority | rst_stream | settings | push_promise | ping | goaway | window_update | continuation | unknown.

%% 解码产物：Flags 与 Payload 原样保留，由上层按 Type 解释。
-type frame() :: {frame, Type :: frame_type(), Flags :: non_neg_integer(), StreamId :: non_neg_integer(), Payload :: binary()}.

%%====================================================================
%% frame 构造
%%====================================================================

%% @doc 构造单个无 flag 的 frame，`frame(Type, StreamId, Payload)' 的简写。
%% @param Type frame 类型原子（或 0..255 的自定义类型号）
%% @param StreamId stream 标识；连接级 frame（SETTINGS/PING/GOAWAY）用 0
%% @param Payload frame 负载，iolist 会先被扁平化成 binary
%% @returns iolist，可直接投递给 socket
-spec frame(frame_type(), non_neg_integer(), iodata()) -> iodata().
frame(Type, StreamId, Payload) ->
   frame(Type, StreamId, Payload, 0).

%% @doc 构造带 flag 的 frame。
%% @param Flags 各 flag 宏的按位或
-spec frame(frame_type(), non_neg_integer(), iodata(), non_neg_integer()) -> iodata().
frame(Type, StreamId, Payload, Flags) ->
   %% Socket API 原生接受 iodata。这里只需要长度来编码 9-byte frame header，
   %% 不应该为了发包先把 HPACK/SETTINGS/DATA 的 iolist 扁平化复制一遍。
   Size = iolist_size(Payload),
   [<<Size:24, (typeNum(Type)):8, Flags:8, 0:1, StreamId:31>>, Payload].

%% @doc 构造 SETTINGS frame，只携带本端想显式设定的项。
%% 未列出的项保持当前值（双方初始都按协议默认值），因此对端无需回显
%% 全部设置。SETTINGS 属于连接级 frame，stream id 固定为 0。
%% @param Settings `[{Setting, Value}]'，如 `[{initial_window_size, 65535}]'
%% @returns iolist
-spec settingsFrame([{atom(), non_neg_integer()}]) -> iodata().
settingsFrame(Settings) ->
   frame(settings, 0, settingsBody(Settings)).

%% 每项 6 字节：2 字节标识符 + 4 字节无符号值（RFC 9113 6.5.1）。
settingsBody(Settings) ->
   [<<(settingId(K)):16, V:32>> || {K, V} <- Settings].

%% @doc 构造 SETTINGS 的 ACK 帧（负载为空 + ACK flag）。
%% 收到对端 SETTINGS 后必须回 ACK，否则对端可能判定 settings_timeout。
-spec ackFrame() -> iodata().
ackFrame() -> frame(settings, 0, <<>>, ?FLAG_ACK).

%% @doc 构造 PING 请求帧，携带 8 字节不透明数据（RFC 9113 6.7 要求恰好 8 字节）。
%% @param Data 8 字节 binary，原样由对端的 PONG 回显
-spec pingFrame(binary()) -> iodata().
pingFrame(Data) when byte_size(Data) =:= 8 ->
   frame(ping, 0, Data).

%% @doc 构造 PING 响应帧（PONG）：回显对端的 8 字节数据并置 ACK flag。
%% 带 ACK 的 PING 不得再被回应，否则会形成应答循环。
-spec pongFrame(binary()) -> iodata().
pongFrame(Data) -> frame(ping, 0, Data, ?FLAG_ACK).

%% @doc 构造 GOAWAY frame：告知对端最后一条已（或将）处理的 stream。
%% @param LastStreamId 对端发起的、本端已处理的最大 stream id
%% @param ErrorCode 关闭原因，原子或原始错误码整数
-spec goawayFrame(non_neg_integer(), atom() | non_neg_integer()) -> iodata().
goawayFrame(LastStreamId, ErrorCode) ->
   %% 负载：R(1) + Last-Stream-ID(31) + Error Code(32)，其后可跟调试数据。
   %% 保留位固定为 0，因此 stream id 只能占用低 31 位。
   frame(goaway, 0, <<0:1, LastStreamId:31, (errorCodeNum(ErrorCode)):32>>).

%% @doc 构造 WINDOW_UPDATE frame，为连接或单条 stream 增加流控窗口。
%% @param StreamId 目标 stream；0 表示连接级窗口
%% @param Increment 增量，必须为正（0 是协议错误），上限 2^31-1
-spec windowUpdateFrame(non_neg_integer(), pos_integer()) -> iodata().
windowUpdateFrame(StreamId, Increment) ->
   %% 最高位为保留位（必须为 0），增量占低 31 位。
   frame(window_update, StreamId, <<0:1, Increment:31>>).

%% @doc 构造 RST_STREAM frame，立即终止一条 stream。
%% @param StreamId 待终止的 stream；不得为 0（连接级错误用 GOAWAY）
%% @param ErrorCode 错误原因，原子或原始错误码整数
-spec rstStreamFrame(non_neg_integer(), atom() | non_neg_integer()) -> iodata().
rstStreamFrame(StreamId, ErrorCode) ->
   frame(rst_stream, StreamId, <<(errorCodeNum(ErrorCode)):32>>).

%% @doc 把一个 HPACK header 块切成 HEADERS + 若干 CONTINUATION frame，
%% 每帧负载不超过 `MaxFrame'，且只有最后一帧带 END_HEADERS。
%% 注意：RFC 9113 要求一个 header block 的 HEADERS + CONTINUATION 必须
%% 连续发送，中间不能插入任何其它 stream 的 frame。
%% @param HeaderBlock 已 HPACK 编码的 header 块
%% @param MaxFrame 对端通告的 SETTINGS_MAX_FRAME_SIZE
%% @returns 可直接发送的 iolist
-spec headersFrames(HeaderBlock, StreamId, MaxFrame) -> iodata() when HeaderBlock :: iodata(), StreamId :: pos_integer(), MaxFrame :: pos_integer().
headersFrames(Block, StreamId, MaxFrame) ->
   headersFrames(Block, StreamId, MaxFrame, false).

%% @doc 构造响应HEADERS。EndStream=true时END_STREAM只出现在首个HEADERS帧；
%% CONTINUATION只能承载END_HEADERS，且整个header block连续发送。
-spec headersFrames(HeaderBlock, StreamId, MaxFrame, EndStream) -> iodata()
   when HeaderBlock :: iodata(), StreamId :: pos_integer(),
      MaxFrame :: pos_integer(), EndStream :: boolean().
headersFrames(Block, StreamId, MaxFrame, EndStream) ->
   BaseFlags = case EndStream of true -> ?FLAG_END_STREAM; false -> 0 end,
   case splitPayload(iolist_to_binary(Block), MaxFrame) of
      [] -> frame(headers, StreamId, <<>>, BaseFlags bor ?FLAG_END_HEADERS);
      [Last] -> frame(headers, StreamId, Last, BaseFlags bor ?FLAG_END_HEADERS);
      [First | Rest] ->
         [frame(headers, StreamId, First, BaseFlags) |
            continuationFrames(Rest, StreamId)]
   end.

continuationFrames([Last], StreamId) ->
   [frame(continuation, StreamId, Last, ?FLAG_END_HEADERS)];
continuationFrames([Chunk | Rest], StreamId) ->
   [frame(continuation, StreamId, Chunk, 0) | continuationFrames(Rest, StreamId)].

%% @doc 把消息体切成 DATA frame 序列，最后一帧带 END_STREAM。
%% 空 body 也要发一个带 END_STREAM 的空 DATA，否则对端不知道响应已结束。
%% @param Body 消息体
%% @param MaxFrame 每帧负载上限
-spec dataFrames(Body, StreamId, MaxFrame) -> iodata() when Body :: binary(), StreamId :: pos_integer(), MaxFrame :: pos_integer().
dataFrames(<<>>, StreamId, _MaxFrame) ->
   frame(data, StreamId, <<>>, ?FLAG_END_STREAM);
dataFrames(Body, StreamId, MaxFrame) ->
   dataFramesLoop(Body, StreamId, MaxFrame).

dataFramesLoop(Bin, StreamId, MaxFrame) when byte_size(Bin) =< MaxFrame ->
   frame(data, StreamId, Bin, ?FLAG_END_STREAM);
dataFramesLoop(<<Chunk:MaxFrame/binary, Rest/binary>>, StreamId, MaxFrame) ->
   [frame(data, StreamId, Chunk, 0) | dataFramesLoop(Rest, StreamId, MaxFrame)].

%% 把 binary 切成不超过 Max 字节的若干块（输入为空时才得到空列表）。
-spec splitPayload(binary(), pos_integer()) -> [binary()].
splitPayload(Bin, Max) when Max > 0 ->
   splitLoop(Bin, Max, []).

splitLoop(<<>>, _Max, Acc) -> lists:reverse(Acc);
splitLoop(Bin, Max, Acc) ->
   case Bin of
      %% 按固定大小 Max 切块：够一块就递归处理剩余部分。
      <<Chunk:Max/binary, Rest/binary>> ->
         splitLoop(Rest, Max, [Chunk | Acc]);
      _ ->
         %% 不足一块的尾巴直接整体收尾。
         lists:reverse([Bin | Acc])
   end.

%%====================================================================
%% SETTINGS 负载编解码
%%====================================================================

%% @doc 解码 SETTINGS 负载为 `[{Setting, Value}]'。
%% 未知标识符以 `{unknown, Id}' 返回，便于上层忽略而不中断连接。
%% @param Bin 原始 SETTINGS 负载
%% @returns `{ok, 列表}'；长度非 6 的倍数时返回 `{error, badSettingsLength}'
-spec settingsDecode(binary()) -> {ok, [{atom(), non_neg_integer()}]} | {error, term()}.
settingsDecode(Bin) when byte_size(Bin) rem 6 =:= 0 ->
   settingsLoop(Bin, []);
settingsDecode(_) ->
   {error, badSettingsLength}.

%% RFC 9113 §6.5：SETTINGS 按出现顺序处理；同一 identifier 重复时
%% 最后出现的值覆盖前值。这里直接 keystore，返回列表中每个 setting
%% 最终只保留一个值，避免上层 proplists:get_value/3 误取旧值。
settingsLoop(<<>>, Acc) -> {ok, Acc};
settingsLoop(<<Id:16, V:32, Rest/binary>>, Acc) ->
   Key = settingAtom(Id),
   settingsLoop(Rest, lists:keystore(Key, 1, Acc, {Key, V})).

%%====================================================================
%% frame 解析器
%%====================================================================

%% 增量解析器：buffer 缓存不足一帧的字节，max_frame 限制对端发来的
%% frame 负载大小。opaque 以免外部依赖内部结构。
-opaque parser() :: #{buffer := binary(), max_frame := pos_integer()}.

%% @doc 新建 frame 解析器。
%% `max_frame' 是**我们**愿意接受的对端 frame 负载上限，即本端通告的
%% SETTINGS_MAX_FRAME_SIZE；起始用协议默认值 16384。
-spec new() -> parser().
new() -> #{buffer => <<>>, max_frame => ?DEFAULT_MAX_FRAME}.

%% @doc 设置本端容忍的最大 frame 负载，即我方通告给对端的
%% SETTINGS_MAX_FRAME_SIZE。严格来说对端在 ACK 该 SETTINGS 之后才允许
%% 发送超过旧上限的 frame；放宽（大于 16384）时立即生效是安全的，
%% 收紧则应等 ACK 后再生效。实际调用时机由 wsHttp2 决定。
%% @param Max 新上限，来自我方 SETTINGS 的 max_frame_size
-spec setMaxFrame(parser(), pos_integer()) -> parser().
setMaxFrame(P, Max) -> P#{max_frame := Max}.

%% @doc 喂入原始字节，返回更新后的 parser 与本次解出的 frame 列表。
%% 列表元素为 `frame' 元组，或 `{error, Reason}'；一旦出现 error 就
%% 停止解析并清空缓冲，由上层按协议错误处理（通常是发 GOAWAY）。
%% @param Bin 新到达的字节（可与上次残留拼接）
%% @returns `{NewParser, [frame() | {error, term()}]}'
-spec feed(parser(), binary()) -> {parser(), [frame() | {error, term()}]}.
feed(#{buffer := <<>>} = P, Bin) ->
   %% 完整帧是绝大多数稳态路径；buffer 为空时直接解析，避免一次无意义的
   %% binary 拼接。只有跨 socket 边界的半帧才进入合并路径。
   feedLoop(P, Bin, []);
feed(#{buffer := Buf} = P, Bin) ->
   feedLoop(P#{buffer := <<>>}, <<Buf/binary, Bin/binary>>, []).

feedLoop(P, Bin, Acc) ->
   case Bin of
      %% 帧头 Stream Identifier 的最高位是保留位，接收端必须忽略
      %% （RFC 9113 §4.1），不能因对端置 1 而断开连接。
      <<Size:24, Type:8, Flags:8, _Reserved:1, StreamId:31, Rest/binary>> ->
         Max = maps:get(max_frame, P),
         if
         %% 超过我们通告的上限即 frame_size_error：不清空就无法
         %% 知道下一帧从哪开始，连接只能放弃。
            Size > Max ->
               {P#{buffer := <<>>}, lists:reverse([{error, {frameTooLarge, Size}} | Acc])};
            true ->
               case Rest of
                  <<Payload:Size/binary, Rest2/binary>> ->
                     feedLoop(P, Rest2, [{frame, typeAtom(Type), Flags, StreamId, Payload} | Acc]);
                  _ ->
                     %% 负载还没收全：整个前缀（含 frame 头）留在
                     %% buffer 里，等下次 feed 时重新解析。
                     {P#{buffer := Bin}, lists:reverse(Acc)}
               end
         end;
      _ when byte_size(Bin) < 9 ->
         %% 连 9 字节 frame 头都不够，直接等更多字节。
         {P#{buffer := Bin}, lists:reverse(Acc)};
      _ ->
         %% 9 字节以上必能由上面的固定宽度帧头模式匹配；此分支仅作
         %% 防御性兜底，保留原始数据等待下一次输入。
         {P#{buffer := Bin}, lists:reverse(Acc)}
   end.

%%====================================================================
%% 负载字段解析（位布局只在这里出现一次）
%%====================================================================

%% GOAWAY 负载：R(1) + Last-Stream-ID(31) + Error Code(32) + 可选调试数据。
%% @returns `{ok, LastStreamId, ErrorCode, DebugData}'
-spec goawayFields(binary()) -> {ok, non_neg_integer(), atom() | integer(), binary()} | {error, term()}.
goawayFields(<<_:1, LastStreamId:31, Code:32, Debug/binary>>) ->
   {ok, LastStreamId, errorCodeAtom(Code), Debug};
goawayFields(_) -> {error, badGoaway}.

%% PING 负载必须是 8 字节不透明数据，长度不符即为 frame_size_error。
-spec pingData(binary()) -> {ok, binary()} | {error, term()}.
pingData(D) when byte_size(D) =:= 8 -> {ok, D};
pingData(_) -> {error, badPing}.

%% WINDOW_UPDATE 负载：R(1) + 31 位增量。增量必须为正，否则是协议错误。
%% 保留位按 RFC 9113 §6.9 接收侧必须忽略（对端置位不构成断连理由），
%% 只取低 31 位为增量；frame header 的保留位同样由 feed/2 忽略
-spec windowUpdateIncrement(binary()) -> {ok, pos_integer()} | {error, term()}.
windowUpdateIncrement(<<_:1, Inc:31>>) when Inc > 0 -> {ok, Inc};
windowUpdateIncrement(<<_:1, 0:31>>) -> {error, zeroIncrement};
windowUpdateIncrement(_) -> {error, badWindowUpdate}.

%% RST_STREAM 负载就是 4 字节错误码。
-spec rstStreamCode(binary()) -> {ok, atom() | integer()} | {error, term()}.
rstStreamCode(<<Code:32>>) -> {ok, errorCodeAtom(Code)};
rstStreamCode(_) -> {error, badRstStream}.

%% PRIORITY frame 负载 / HEADERS 的 PRIORITY 字段：
%% Exclusive(1) + Stream Dependency(31) + Weight(8)。
%% Weight 实际取值 1..256，这里不强校验，交由上层决定。
%% @returns `{ok, Exclusive, DepStreamId, Weight, 剩余字节}'
-spec priorityFields(binary()) -> {ok, Exclusive :: boolean(), DepStreamId :: non_neg_integer(), Weight :: non_neg_integer(), Rest :: binary()} | {error, term()}.
priorityFields(<<E:1, Dep:31, W:8, Rest/binary>>) ->
   {ok, E =:= 1, Dep, W, Rest};
priorityFields(_) ->
   {error, badPriority}.

%%====================================================================
%% 查表
%%====================================================================

%% 类型原子 -> 线路编号。整数直接透传，便于构造扩展类型。
typeNum(data) -> ?DATA;
typeNum(headers) -> ?HEADERS;
typeNum(priority) -> ?PRIORITY;
typeNum(rst_stream) -> ?RST_STREAM;
typeNum(settings) -> ?SETTINGS;
typeNum(push_promise) -> ?PUSH_PROMISE;
typeNum(ping) -> ?PING;
typeNum(goaway) -> ?GOAWAY;
typeNum(window_update) -> ?WINDOW_UPDATE;
typeNum(continuation) -> ?CONTINUATION;
typeNum(N) when is_integer(N), N >= 0, N =< 255 -> N.

%% 线路编号 -> 类型原子。未知编号包装成 `{unknown, N}'，交给上层忽略。
typeAtom(?DATA) -> data;
typeAtom(?HEADERS) -> headers;
typeAtom(?PRIORITY) -> priority;
typeAtom(?RST_STREAM) -> rst_stream;
typeAtom(?SETTINGS) -> settings;
typeAtom(?PUSH_PROMISE) -> push_promise;
typeAtom(?PING) -> ping;
typeAtom(?GOAWAY) -> goaway;
typeAtom(?WINDOW_UPDATE) -> window_update;
typeAtom(?CONTINUATION) -> continuation;
typeAtom(N) when is_integer(N) -> {unknown, N}.

%% SETTINGS 标识符（RFC 9113 6.5.2）。
settingId(header_table_size) -> 16#01;
settingId(enable_push) -> 16#02;
settingId(max_concurrent_streams) -> 16#03;
settingId(initial_window_size) -> 16#04;
settingId(max_frame_size) -> 16#05;
settingId(max_header_list_size) -> 16#06.

%% SETTINGS 标识符 -> 原子，未知标识符保留原值以便透传。
settingAtom(16#01) -> header_table_size;
settingAtom(16#02) -> enable_push;
settingAtom(16#03) -> max_concurrent_streams;
settingAtom(16#04) -> initial_window_size;
settingAtom(16#05) -> max_frame_size;
settingAtom(16#06) -> max_header_list_size;
settingAtom(N) when is_integer(N) -> {unknown, N}.

errorCodeNum(no_error) -> 16#0;
errorCodeNum(protocol_error) -> 16#1;
errorCodeNum(internal_error) -> 16#2;
errorCodeNum(flow_control_error) -> 16#3;
errorCodeNum(settings_timeout) -> 16#4;
errorCodeNum(stream_closed) -> 16#5;
errorCodeNum(frame_size_error) -> 16#6;
errorCodeNum(refused_stream) -> 16#7;
errorCodeNum(cancel) -> 16#8;
errorCodeNum(compression_error) -> 16#9;
errorCodeNum(connect_error) -> 16#a;
errorCodeNum(enhance_your_calm) -> 16#b;
errorCodeNum(inadequate_security) -> 16#c;
errorCodeNum(http_1_1_required) -> 16#d;
errorCodeNum(N) when is_integer(N) -> N.

errorCodeAtom(16#0) -> no_error;
errorCodeAtom(16#1) -> protocol_error;
errorCodeAtom(16#2) -> internal_error;
errorCodeAtom(16#3) -> flow_control_error;
errorCodeAtom(16#4) -> settings_timeout;
errorCodeAtom(16#5) -> stream_closed;
errorCodeAtom(16#6) -> frame_size_error;
errorCodeAtom(16#7) -> refused_stream;
errorCodeAtom(16#8) -> cancel;
errorCodeAtom(16#9) -> compression_error;
errorCodeAtom(16#a) -> connect_error;
errorCodeAtom(16#b) -> enhance_your_calm;
errorCodeAtom(16#c) -> inadequate_security;
errorCodeAtom(16#d) -> http_1_1_required;
errorCodeAtom(N) when is_integer(N) -> N.
