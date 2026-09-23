-module(wsHttp2).

-include("wsCom.hrl").

-export([
   new/6
   , new/8
   , start/1
   , handleData/2
   , handleResponse/5
   , handleWorkerDown/3
   , handleRequestTimeout/3
   , handleSettingsTimeout/2
   , handleStreamStart/7
   , handleStreamChunk/6
   , handleStreamClose/4
   , resumePending/1
   , hasOpenStreams/1
   , idleClose/1
   , terminate/1
]).

-define(PREFACE, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>).
-define(END_STREAM, 16#01).
-define(ACK, 16#01).
-define(END_HEADERS, 16#04).
-define(PADDED, 16#08).
-define(PRIORITY, 16#20).
-define(MAX_WINDOW, 16#7fffffff).
-define(DEFAULT_WINDOW, 65535).
-define(DEFAULT_MAX_FRAME, 16384).
-define(DEFAULT_MAX_STREAMS, 100).
%% 本端广播的 SETTINGS_HEADER_TABLE_SIZE。解码端动态表上限（wsHpack 的 limit）
%% 必须与它同源：对端只被允许把动态表扩到本端宣布的这个值，两边写死成两个
%% 数字就会在以后调整时悄悄错开，合法的大小更新会被误判成压缩错误。
-define(LOCAL_HEADER_TABLE_SIZE, 4096).
%% 一个头部块里 HEADERS + CONTINUATION 的帧数上限。空 CONTINUATION
%% 不增加字节计数，没有这个上限就能把片段列表撑到耗尽内存。
-define(MAX_CONTINUATION_FRAMES, 32).
%% 客户端在收到响应前重置流的速率上限（CVE-2023-44487）。
-define(RAPID_RESET_LIMIT, 100).
-define(RAPID_RESET_WINDOW_MS, 1000).
-define(SETTINGS_ACK_TIMEOUT, 10000).
-define(PING_LIMIT, 100).
-define(SETTINGS_LIMIT, 10).
-define(PRIORITY_LIMIT, 200).
-define(FRAME_RATE_WINDOW_MS, 1000).
%% 单次 socket send 最多聚合这么多 DATA payload。减少 syscall/BIF 次数，
%% 同时避免超大窗口下一次 send 构造过大的 iolist、长期占住 connection owner。
-define(SEND_BATCH_BYTES, 256 * 1024).

%% HTTP/2 server connection state. Socket ownership remains in wsHttp; this
%% module is a protocol state machine and performs writes through wsNet.
-spec new(wsSocket(), module(), http | https, non_neg_integer() | infinity, pos_integer(), pos_integer()) -> map().
new(Socket, WsMod, Scheme, MaxBody, MaxHeader, RequestTimeout) ->
   new(Socket, WsMod, Scheme, MaxBody, MaxHeader, RequestTimeout,
      ?DEFAULT_MAX_STREAMS, ?DEFAULT_WINDOW).

-spec new(wsSocket(), module(), http | https, non_neg_integer() | infinity,
   pos_integer(), pos_integer(), pos_integer(), 65535..2147483647) -> map().
new(Socket, WsMod, Scheme, MaxBody, MaxHeader, RequestTimeout, MaxConcurrent, ReceiveWindow) ->
   #{
      socket => Socket,
      ws_mod => WsMod,
      scheme => Scheme,
      phase => preface,
      preface_buffer => <<>>,
      parser => wsHttp2Frame:new(),
      rx_hpack => wsHpack:new(?LOCAL_HEADER_TABLE_SIZE),
      %% 编码端起点是协议初值 4096：对端在发来 SETTINGS_HEADER_TABLE_SIZE
      %% 之前，本端只能按协议默认值编码。
      tx_hpack => wsHpack:new(),
      streams => #{},
      send_pending_streams => #{},
      flush_scheduled => false,
      header_frames => none,
      last_client_stream => 0,
      need_client_settings => true,
      expect_settings_ack => false,
      peer_max_frame => ?DEFAULT_MAX_FRAME,
      peer_initial_window => ?DEFAULT_WINDOW,
      peer_max_concurrent => infinity,
      peer_max_header_list => infinity,
      send_conn_window => ?DEFAULT_WINDOW,
      %% connection receive window 的协议初值固定是 65535；start/1 在
      %% ReceiveWindow 更大时发送 connection WINDOW_UPDATE 后再同步本地值。
      recv_conn_window => ?DEFAULT_WINDOW,
      local_initial_window => ReceiveWindow,
      max_body => MaxBody,
      max_header => MaxHeader,
      request_timeout => RequestTimeout,
      max_concurrent_streams => MaxConcurrent,
      goaway => false,
      pending_conn_credit => 0,
      pending_stream_credits => #{},
      wu_conn_pending => 0,
      rapid_resets => 0,
      rapid_reset_ts => 0,
      frame_rates => #{},
      settings_ack_timer => undefined,
      settings_ack_token => undefined
   }.

-spec start(map()) -> {ok, map()} | {error, term()}.
start(State0) ->
   ReceiveWindow = maps:get(local_initial_window, State0),
   Settings = [
      {header_table_size, ?LOCAL_HEADER_TABLE_SIZE},
      {enable_push, 0},
      {max_concurrent_streams, maps:get(max_concurrent_streams, State0)},
      {initial_window_size, ReceiveWindow},
      {max_frame_size, ?DEFAULT_MAX_FRAME},
      {max_header_list_size, maps:get(max_header, State0)}
   ],
   %% SETTINGS_INITIAL_WINDOW_SIZE 只调整 stream window，connection window
   %% 仍从 65535 起步。配置大接收窗时必须另发 stream-id 0 WINDOW_UPDATE。
   Frames =
      case ReceiveWindow - ?DEFAULT_WINDOW of
         0 ->
            wsHttp2Frame:settingsFrame(Settings);
         Delta when Delta > 0 ->
            [wsHttp2Frame:settingsFrame(Settings),
             wsHttp2Frame:windowUpdateFrame(0, Delta)]
      end,
   case wsNet:send(maps:get(socket, State0), Frames) of
      ok ->
         Token = make_ref(),
         Timer = erlang:send_after(?SETTINGS_ACK_TIMEOUT, self(), {h2_settings_ack_timeout, Token}),
         {ok, State0#{
            recv_conn_window => ReceiveWindow,
            expect_settings_ack => true,
            settings_ack_timer => Timer,
            settings_ack_token => Token
         }};
      {error, Reason} -> {error, Reason}
   end.

-spec handleData(binary(), map()) -> {ok, map()} | {stop, term(), map()}.
handleData(Data, #{phase := preface} = State) ->
   handlePreface(Data, State);
handleData(Data, State) ->
   handleFrames(Data, State).

handlePreface(Data, #{preface_buffer := Buf} = State) ->
   All = <<Buf/binary, Data/binary>>,
   Need = byte_size(?PREFACE),
   case byte_size(All) >= Need of
      false ->
         Prefix = binary:part(?PREFACE, 0, byte_size(All)),
         case All =:= Prefix of
            true -> {ok, State#{preface_buffer => All}};
            false -> connError(protocol_error, invalid_preface, State)
         end;
      true ->
         <<Preface:Need/binary, Rest/binary>> = All,
         case Preface =:= ?PREFACE of
            false -> connError(protocol_error, invalid_preface, State);
            true ->
               NState = State#{phase => frames, preface_buffer => <<>>},
               case Rest of
                  <<>> -> {ok, NState};
                  _ -> handleFrames(Rest, NState)
               end
         end
   end.

handleFrames(Data, #{parser := Parser0} = State0) ->
   {Parser, Frames} = wsHttp2Frame:feed(Parser0, Data),
   %% 本批字节是对端在看到本批 WINDOW_UPDATE 之前发出的，窗口要等整批
   %% 解析完再补回，否则同一 recv 里的后续 DATA 会绕过流量窗口。
   case applyFrames(Frames, State0#{parser => Parser, pending_conn_credit => 0}) of
      {ok, State1} -> {ok, applyRecvCredit(State1)};
      {stop, Reason, State1} -> {stop, Reason, State1}
   end.

applyFrames([], State) ->
   {ok, State};
applyFrames([{error, Reason} | _], State) ->
   connError(frame_size_error, {frame_error, Reason}, State);
applyFrames([{frame, Type, Flags, StreamId, Payload} = Frame | Rest], State0) ->
   case maps:get(header_frames, State0) of
      none ->
         case validateFrame(Type, Flags, StreamId, Payload) of
            ok ->
               case requireInitialSettings(Frame, State0) of
                  {ok, State1} -> dispatch(Type, Flags, StreamId, Payload, Rest, State1);
                  {error, Reason} -> connError(protocol_error, Reason, State0)
               end;
            {error, frame_size_error, Reason} when Type =:= priority, StreamId =/= 0 ->
               State1 = streamError(StreamId, frame_size_error, State0),
               ?wsWarn("HTTP/2 PRIORITY frame size error stream=~p reason=~p", [StreamId, Reason]),
               applyFrames(Rest, State1);
            {error, Code, Reason} ->
               connError(Code, Reason, State0)
         end;
      {StreamId, _Kind, _EndStream, _Acc, _Size, _Count} when Type =:= continuation ->
         case validateFrame(continuation, Flags, StreamId, Payload) of
            ok -> applyContinuation(Flags, StreamId, Payload, Rest, State0);
            {error, Code, Reason} -> connError(Code, Reason, State0)
         end;
      {_PendingStream, _Kind, _EndStream, _Acc, _Size, _Count} ->
         connError(protocol_error, expected_continuation, State0)
   end.

requireInitialSettings({frame, settings, Flags, 0, _}, #{need_client_settings := true} = State)
   when Flags band ?ACK =:= 0 ->
   {ok, State#{need_client_settings => false}};
requireInitialSettings(_Frame, #{need_client_settings := true}) ->
   {error, first_frame_must_be_settings};
requireInitialSettings(_Frame, State) ->
   {ok, State}.

validateFrame(Type, _Flags, StreamId, Payload) ->
   %% RFC 9113 §4.1: 未定义/未使用的 flag 位在接收端必须忽略。
   %% 各 frame 处理函数只读取自己理解的 flag，扩展 flag 不应导致断连。
   validateStreamId(Type, StreamId, Payload).

validateStreamId(Type, 0, _Payload)
   when Type =:= data; Type =:= headers; Type =:= priority;
        Type =:= rst_stream; Type =:= push_promise; Type =:= continuation ->
   {error, protocol_error, {stream_zero, Type}};
validateStreamId(Type, StreamId, _Payload)
   when StreamId =/= 0, (Type =:= settings orelse Type =:= ping orelse Type =:= goaway) ->
   {error, protocol_error, {stream_nonzero, Type}};
validateStreamId(priority, _StreamId, Payload) when byte_size(Payload) =/= 5 ->
   {error, frame_size_error, bad_priority_size};
validateStreamId(rst_stream, _StreamId, Payload) when byte_size(Payload) =/= 4 ->
   {error, frame_size_error, bad_rst_stream_size};
validateStreamId(ping, _StreamId, Payload) when byte_size(Payload) =/= 8 ->
   {error, frame_size_error, bad_ping_size};
validateStreamId(window_update, _StreamId, Payload) when byte_size(Payload) =/= 4 ->
   {error, frame_size_error, bad_window_update_size};
validateStreamId(goaway, _StreamId, Payload) when byte_size(Payload) < 8 ->
   {error, frame_size_error, bad_goaway_size};
validateStreamId(_Type, _StreamId, _Payload) ->
   ok.

dispatch(settings, Flags, 0, Payload, Rest, State) ->
   case allowFrame(settings, ?SETTINGS_LIMIT, State) of
      {error, State1} -> connError(enhance_your_calm, settings_flood, State1);
      {ok, State1} -> dispatchSettings(Flags, Payload, Rest, State1)
   end;
dispatch(ping, Flags, 0, Payload, Rest, State) ->
   case allowFrame(ping, ?PING_LIMIT, State) of
      {error, State1} -> connError(enhance_your_calm, ping_flood, State1);
      {ok, State1} -> dispatchPing(Flags, Payload, Rest, State1)
   end;
dispatch(window_update, _Flags, StreamId, Payload, Rest, State) ->
   case {StreamId, streamState(StreamId, State)} of
      {0, _} ->
         applyWindowUpdateFrame(StreamId, Payload, Rest, State);
      {_Id, idle} ->
         connError(protocol_error, {window_update_on_idle_stream, StreamId}, State);
      {_Id, closed} ->
         %% WINDOW_UPDATE can legitimately race with END_STREAM/RST_STREAM.
         applyFrames(Rest, State);
      {_Id, open} ->
         applyWindowUpdateFrame(StreamId, Payload, Rest, State)
   end;

dispatch(headers, Flags, StreamId, Payload, Rest, State) ->
   applyHeaders(Flags, StreamId, Payload, Rest, State);
dispatch(continuation, _Flags, _StreamId, _Payload, _Rest, State) ->
   connError(protocol_error, unexpected_continuation, State);
dispatch(data, Flags, StreamId, Payload, Rest, State) ->
   applyData(Flags, StreamId, Payload, Rest, State);
dispatch(rst_stream, _Flags, StreamId, _Payload, Rest, State) ->
   case streamState(StreamId, State) of
      idle ->
         connError(protocol_error, {rst_stream_on_idle, StreamId}, State);
      _ ->
         case noteRapidReset(StreamId, State) of
            {error, State1} ->
               connError(enhance_your_calm, rapid_reset, State1);
            {ok, State1} ->
               applyFrames(Rest, dropStream(StreamId, State1))
         end
   end;
dispatch(priority, _Flags, StreamId, Payload, Rest, State0) ->
   case allowFrame(priority, ?PRIORITY_LIMIT, State0) of
      {error, State1} -> connError(enhance_your_calm, priority_flood, State1);
      {ok, State} ->
         case wsHttp2Frame:priorityFields(Payload) of
            {ok, _Exclusive, StreamId, _Weight, _} ->
               State1 = streamError(StreamId, protocol_error, State),
               applyFrames(Rest, State1);
            {ok, _Exclusive, _Dep, _Weight, <<>>} ->
               applyFrames(Rest, State);
            _ ->
               %% Length errors are handled by validateFrame/4 before dispatch.
               applyFrames(Rest, State)
         end
   end;
dispatch(push_promise, _Flags, _StreamId, _Payload, _Rest, State) ->
   %% Clients cannot send PUSH_PROMISE.
   connError(protocol_error, client_push_promise, State);
dispatch(goaway, _Flags, 0, Payload, Rest, State) ->
   case wsHttp2Frame:goawayFields(Payload) of
      {ok, _Last, no_error, _Debug} ->
         %% GOAWAY(NO_ERROR) 启动优雅关闭：禁止新 stream，但已有 stream
         %% 仍应完成。立即断开会让已执行的非幂等请求变成结果不确定。
         applyFrames(Rest, State#{goaway => true});
      {ok, _Last, Code, _Debug} ->
         {stop, {peer_goaway, Code}, State#{goaway => true}};
      {error, Reason} ->
         connError(frame_size_error, Reason, State)
   end;
dispatch({unknown, _}, _Flags, _StreamId, _Payload, Rest, State) ->
   applyFrames(Rest, State);
dispatch(_Other, _Flags, _StreamId, _Payload, Rest, State) ->
   applyFrames(Rest, State).

dispatchSettings(Flags, Payload, Rest, State) ->
   case Flags band ?ACK of
      ?ACK ->
         case {Payload, maps:get(expect_settings_ack, State, false)} of
            {<<>>, true} ->
               applyFrames(Rest, cancelSettingsTimer(State#{expect_settings_ack => false}));
            {<<>>, false} -> connError(protocol_error, unexpected_settings_ack, State);
            _ -> connError(frame_size_error, settings_ack_payload, State)
         end;
      _ ->
         case wsHttp2Frame:settingsDecode(Payload) of
            {ok, Settings} ->
               case applyPeerSettings(Settings, State) of
                  {ok, State1} ->
                     case wsNet:send(maps:get(socket, State1), wsHttp2Frame:ackFrame()) of
                        ok -> applyFrames(Rest, State1);
                        {error, Reason} -> {stop, {socket_error, Reason}, State1}
                     end;
                  {error, Code, Reason} ->
                     connError(Code, Reason, State)
               end;
            {error, Reason} ->
               connError(protocol_error, {bad_settings, Reason}, State)
         end
   end.

dispatchPing(Flags, Payload, Rest, State) ->
   case Flags band ?ACK of
      ?ACK -> applyFrames(Rest, State);
      _ ->
         case wsNet:send(maps:get(socket, State), wsHttp2Frame:pongFrame(Payload)) of
            ok -> applyFrames(Rest, State);
            {error, Reason} -> {stop, {socket_error, Reason}, State}
         end
   end.

applyWindowUpdateFrame(StreamId, Payload, Rest, State) ->
   case wsHttp2Frame:windowUpdateIncrement(Payload) of
      {ok, Inc} ->
         case applyWindowUpdate(StreamId, Inc, State) of
            {ok, State1} -> applyFrames(Rest, State1);
            {stream_error, State1} -> applyFrames(Rest, State1);
            {error, Code, Reason} -> connError(Code, Reason, State)
         end;
      {error, zeroIncrement} when StreamId =:= 0 ->
         connError(protocol_error, zero_connection_window_increment, State);
      {error, zeroIncrement} ->
         State1 = streamError(StreamId, protocol_error, State),
         applyFrames(Rest, State1);
      {error, Reason} ->
         connError(frame_size_error, Reason, State)
   end.

streamState(0, _State) ->
   connection;
streamState(StreamId, State) ->
   case maps:is_key(StreamId, maps:get(streams, State)) of
      true ->
         open;
      false ->
         Last = maps:get(last_client_stream, State, 0),
         case StreamId band 1 of
            0 -> idle;  %% Server push is not implemented; no even stream can exist.
            1 when StreamId =< Last -> closed;
            1 -> idle
         end
   end.

applyPeerSettings(Settings, State0) ->
   case validateSettings(Settings) of
      ok ->
         OldInitial = maps:get(peer_initial_window, State0),
         NewInitial = proplists:get_value(initial_window_size, Settings, OldInitial),
         Delta = NewInitial - OldInitial,
         Streams0 = maps:get(streams, State0),
         case adjustSendWindows(Streams0, Delta) of
            {error, overflow} ->
               {error, flow_control_error, initial_window_overflow};
            Streams ->
               Tx0 = maps:get(tx_hpack, State0),
               Tx = case proplists:get_value(header_table_size, Settings, undefined) of
                  undefined -> Tx0;
                  N -> wsHpack:setMax(erlang:min(N, 65536), Tx0)
               end,
               State1 = State0#{
                  streams => Streams,
                  tx_hpack => Tx,
                  peer_initial_window => NewInitial,
                  peer_max_frame => proplists:get_value(max_frame_size, Settings, maps:get(peer_max_frame, State0)),
                  peer_max_concurrent => proplists:get_value(max_concurrent_streams, Settings, maps:get(peer_max_concurrent, State0)),
                  peer_max_header_list => proplists:get_value(
                     max_header_list_size, Settings, maps:get(peer_max_header_list, State0))
               },
               flushAllPending(State1)
         end;
      {error, Code, Reason} ->
         {error, Code, Reason}
   end.

validateSettings(Settings) ->
   case proplists:get_value(enable_push, Settings, 0) of
      V when V =:= 0; V =:= 1 ->
         MaxFrame = proplists:get_value(max_frame_size, Settings, ?DEFAULT_MAX_FRAME),
         InitWin = proplists:get_value(initial_window_size, Settings, ?DEFAULT_WINDOW),
         case MaxFrame >= 16384 andalso MaxFrame =< 16777215 of
            false -> {error, protocol_error, {bad_max_frame_size, MaxFrame}};
            true when InitWin > ?MAX_WINDOW -> {error, flow_control_error, {bad_initial_window, InitWin}};
            true -> ok
         end;
      Bad ->
         {error, protocol_error, {bad_enable_push, Bad}}
   end.

adjustSendWindows(Streams, 0) -> Streams;
adjustSendWindows(Streams, Delta) ->
   maps:fold(fun(Id, Stream, Acc) ->
      case Acc of
         {error, _} -> Acc;
         Map ->
            Win = maps:get(send_window, Stream, ?DEFAULT_WINDOW) + Delta,
            case Win > ?MAX_WINDOW of
               true -> {error, overflow};
               false -> Map#{Id => Stream#{send_window => Win}}
            end
      end
   end, #{}, Streams).

applyWindowUpdate(0, Inc, State) ->
   New = maps:get(send_conn_window, State) + Inc,
   case New > ?MAX_WINDOW of
      true -> {error, flow_control_error, connection_window_overflow};
      false -> flushAllPending(State#{send_conn_window => New})
   end;
applyWindowUpdate(StreamId, Inc, State) ->
   Streams = maps:get(streams, State),
   case maps:get(StreamId, Streams, undefined) of
      undefined ->
         %% WINDOW_UPDATE for a closed stream may be ignored.
         {ok, State};
      Stream ->
         New = maps:get(send_window, Stream) + Inc,
         case New > ?MAX_WINDOW of
            true ->
               {stream_error, streamError(StreamId, flow_control_error, State)};
            false ->
               State1 = State#{streams => Streams#{StreamId := Stream#{send_window => New}}},
               flushPending(StreamId, State1)
         end
   end.

applyHeaders(Flags, StreamId, Payload, Rest, State0) ->
   case stripHeadersPayload(Flags, StreamId, Payload) of
      {error, Reason} ->
         connError(protocol_error, Reason, State0);
      {ok, Block} ->
         EndStream = Flags band ?END_STREAM =/= 0,
         EndHeaders = Flags band ?END_HEADERS =/= 0,
         case classifyHeaders(StreamId, State0) of
            {connection_error, Reason} ->
               connError(protocol_error, Reason, State0);
            Kind ->
               %% A valid HEADERS frame opens a new peer stream immediately.
               %% Advance the high-water mark even if request validation later
               %% rejects the stream, so identifiers can never be reused.
               State1 = case Kind of
                  initial -> State0#{last_client_stream => StreamId};
                  {reject_new, _} -> State0#{last_client_stream => StreamId};
                  _ -> State0
               end,
               Size = byte_size(Block),
               case Size > maps:get(max_header, State1) of
                  true ->
                     %% Closing the connection is intentional here: skipping an
                     %% oversized HPACK block and continuing would desynchronize
                     %% the connection-wide dynamic table.
                     connError(enhance_your_calm, header_block_too_large, State1);
                  false when EndHeaders ->
                     finishHeaderBlock(StreamId, Kind, EndStream, Block, Rest, State1);
                  false ->
                     State2 = State1#{header_frames => {StreamId, Kind, EndStream, [Block], Size, 1}},
                     applyFrames(Rest, State2)
               end
         end
   end.

classifyHeaders(StreamId, State) ->
   Streams = maps:get(streams, State),
   case maps:get(StreamId, Streams, undefined) of
      #{remote_closed := true} ->
         {reject, stream_closed};
      Stream when is_map(Stream) ->
         trailer;
      undefined ->
         Last = maps:get(last_client_stream, State),
         case {StreamId band 1, StreamId > Last, maps:get(goaway, State, false)} of
            {1, true, false} ->
               case map_size(Streams) < maps:get(max_concurrent_streams, State) of
                  true -> initial;
                  false -> {reject_new, refused_stream}
               end;
            {0, _, _} ->
               {connection_error, client_stream_must_be_odd};
            {1, false, _} ->
               %% All lower peer stream IDs are already in the closed state
               %% (opened earlier or implicitly skipped by a higher ID).
               discard_closed;
            {_, _, true} ->
               {connection_error, stream_after_goaway}
         end
   end.

applyContinuation(Flags, StreamId, Payload, Rest,
   #{header_frames := {StreamId, Kind, EndStream, Acc, Size0, Count0}} = State0) ->
   Count = Count0 + 1,
   Size = Size0 + byte_size(Payload),
   TooBig = Size > maps:get(max_header, State0),
   case Count > ?MAX_CONTINUATION_FRAMES of
      true ->
         connError(enhance_your_calm, too_many_continuations, State0#{header_frames => none});
      false when TooBig ->
         %% We cannot skip the rest of a HPACK field block and keep using the
         %% connection: the dynamic table might be modified by skipped bytes.
         connError(enhance_your_calm, header_block_too_large, State0#{header_frames => none});
      false ->
         EndHeaders = Flags band ?END_HEADERS =/= 0,
         case EndHeaders of
            false ->
               State1 = State0#{header_frames => {StreamId, Kind, EndStream, [Payload | Acc], Size, Count}},
               applyFrames(Rest, State1);
            true ->
               Block = iolist_to_binary(lists:reverse([Payload | Acc])),
               finishHeaderBlock(StreamId, Kind, EndStream, Block, Rest, State0#{header_frames => none})
         end
   end;
applyContinuation(_Flags, _StreamId, _Payload, _Rest, State) ->
   connError(protocol_error, wrong_continuation_stream, State).

finishHeaderBlock(StreamId, Kind, EndStream, Block, Rest, State0) ->
   Rx0 = maps:get(rx_hpack, State0),
   case wsHpack:decode(Block, Rx0) of
      {error, Reason} ->
         connError(compression_error, {hpack, Reason}, State0);
      {ok, Headers, Rx} ->
         State1 = State0#{rx_hpack => Rx, header_frames => none},
         {HeaderBytes, HeaderCount} = headerListStats(Headers),
         case HeaderBytes > maps:get(max_header, State1) orelse HeaderCount > 100 of
            true ->
               State2 = streamError(StreamId, enhance_your_calm, State1),
               applyFrames(Rest, State2);
            false ->
               case Kind of
                  initial ->
                     finishInitialHeaders(StreamId, EndStream, Headers, Rest, State1);
                  trailer ->
                     finishTrailers(StreamId, EndStream, Headers, Rest, State1);
                  {reject_new, Code} ->
                     State2 = streamError(StreamId, Code, State1),
                     applyFrames(Rest, State2);
                  {reject, Code} ->
                     State2 = streamError(StreamId, Code, State1),
                     applyFrames(Rest, State2);
                  discard_closed ->
                     %% HPACK 状态已经推进。已关闭或被跳过的流再收到
                     %% HEADERS 必须回 RST_STREAM(STREAM_CLOSED)。
                     State2 = streamError(StreamId, stream_closed, State1),
                     applyFrames(Rest, State2)
               end
         end
   end.

finishInitialHeaders(StreamId, EndStream, Headers, Rest, State0) ->
   case requestFromHeaders(Headers, State0) of
      {error, Reason} ->
         State1 = streamError(StreamId, protocol_error, State0),
         ?wsWarn("HTTP/2 bad request headers stream=~p reason=~p", [StreamId, Reason]),
         applyFrames(Rest, State1);
      {ok, Req, ContentLength} ->
         Stream0 = #{
            req => Req,
            body_acc => [],
            body_size => 0,
            content_length => ContentLength,
            recv_window => maps:get(local_initial_window, State0),
            send_window => maps:get(peer_initial_window, State0),
            pending_send => <<>>,
            response_started => false,
            remote_closed => EndStream
         },
         %% 从收到请求头开始计时，直到流被关闭。卡在发送窗口或
         %% handler 上的流也会在 request_timeout 后被重置。
         Stream = armRequestTimer(StreamId, Stream0, State0),
         State1 = State0#{streams => (maps:get(streams, State0))#{StreamId => Stream}, last_client_stream => StreamId},
         case EndStream of
            true ->
               case validateRequestLength(Stream) of
                  ok ->
                     case dispatchRequest(StreamId, State1) of
                        {ok, State2} -> applyFrames(Rest, State2);
                        Stop -> Stop
                     end;
                  {error, _} ->
                     State2 = streamError(StreamId, protocol_error, State1),
                     applyFrames(Rest, State2)
               end;
            false ->
               applyFrames(Rest, State1)
         end
   end.

finishTrailers(StreamId, EndStream, Headers, Rest, State0) ->
   case EndStream of
      false ->
         State1 = streamError(StreamId, protocol_error, State0),
         applyFrames(Rest, State1);
      true ->
         case validateTrailerHeaders(Headers) of
            ok ->
               Streams = maps:get(streams, State0),
               case maps:get(StreamId, Streams, undefined) of
                  undefined ->
                     applyFrames(Rest, State0);
                  Stream ->
                     Req0 = maps:get(req, Stream),
                     TrailerHeaders = internalHeaders(Headers),
                     %% Keep legacy merged headers for compatibility, but expose
                     %% the trailer section explicitly through #wsReq.trailers.
                     Req = Req0#wsReq{
                        headers = Req0#wsReq.headers ++ TrailerHeaders,
                        trailers = TrailerHeaders
                     },
                     Stream1 = Stream#{req => Req},
                     State1 = State0#{streams => Streams#{StreamId := Stream1}},
                     case validateRequestLength(Stream1) of
                        ok ->
                           case dispatchRequest(StreamId, State1) of
                              {ok, State2} -> applyFrames(Rest, State2);
                              Stop -> Stop
                           end;
                        {error, _} ->
                           State2 = streamError(StreamId, protocol_error, State1),
                           applyFrames(Rest, State2)
                     end
               end;
            {error, _Reason} ->
               State1 = streamError(StreamId, protocol_error, State0),
               applyFrames(Rest, State1)
         end
   end.

applyData(Flags, StreamId, Payload, Rest, State0) ->
   Streams = maps:get(streams, State0),
   case maps:get(StreamId, Streams, undefined) of
      undefined ->
         case streamState(StreamId, State0) of
            idle ->
               connError(protocol_error, {data_on_idle_stream, StreamId}, State0);
            closed ->
               discardClosedData(Flags, StreamId, Payload, Rest, State0);
            _ ->
               connError(protocol_error, {data_invalid_stream, StreamId}, State0)
         end;
      #{remote_closed := true} ->
         %% DATA after END_STREAM is a stream error, but the complete DATA
         %% payload still consumes connection flow-control credit.
         discardClosedData(Flags, StreamId, Payload, Rest, State0);
      Stream0 ->
         FlowBytes = byte_size(Payload),
         ConnWin = maps:get(recv_conn_window, State0),
         StreamWin = maps:get(recv_window, Stream0),
         case {FlowBytes =< ConnWin, FlowBytes =< StreamWin} of
            {false, _} ->
               connError(flow_control_error, connection_receive_window_exceeded, State0);
            {_, false} ->
               %% 流窗口不足仍是 stream error，但 DATA 已占用连接窗口。
               State1 = State0#{recv_conn_window => ConnWin - FlowBytes},
               case replenishConnectionWindow(FlowBytes, State1) of
                  {error, Reason, State2} ->
                     {stop, {socket_error, Reason}, State2};
                  {ok, State2} ->
                     State3 = streamError(StreamId, flow_control_error, State2),
                     applyFrames(Rest, State3)
               end;
            {true, true} ->
               case stripDataPayload(Flags, Payload) of
                  {error, Reason} ->
                     %% 帧已计入连接窗口，即使 padding 非法也要记账。
                     State1 = State0#{recv_conn_window => ConnWin - FlowBytes},
                     case replenishConnectionWindow(FlowBytes, State1) of
                        {error, SockReason, State2} ->
                           {stop, {socket_error, SockReason}, State2};
                        {ok, State2} ->
                           connError(protocol_error, Reason, State2)
                     end;
                  {ok, BodyPart} ->
                     Size = maps:get(body_size, Stream0) + byte_size(BodyPart),
                     case exceeds(Size, maps:get(max_body, State0)) of
                        true ->
                           State1 = State0#{
                              recv_conn_window => ConnWin - FlowBytes,
                              streams => Streams#{StreamId := Stream0#{
                                 recv_window => StreamWin - FlowBytes
                              }}
                           },
                           case replenishReceiveWindows(StreamId, FlowBytes, State1) of
                              {error, Reason, State2} ->
                                 {stop, {socket_error, Reason}, State2};
                              {ok, State2} ->
                                 State3 = streamError(StreamId, enhance_your_calm, State2),
                                 applyFrames(Rest, State3)
                           end;
                        false ->
                           Stream1 = Stream0#{
                              body_acc => [BodyPart | maps:get(body_acc, Stream0)],
                              body_size => Size,
                              recv_window => StreamWin - FlowBytes
                           },
                           State1 = State0#{
                              recv_conn_window => ConnWin - FlowBytes,
                              streams => Streams#{StreamId := Stream1}
                           },
                           case replenishReceiveWindows(StreamId, FlowBytes, State1) of
                              {error, Reason, State2} ->
                                 {stop, {socket_error, Reason}, State2};
                              {ok, State2} ->
                                 case Flags band ?END_STREAM =/= 0 of
                                    false ->
                                       applyFrames(Rest, State2);
                                    true ->
                                       Stream2 = maps:get(StreamId, maps:get(streams, State2)),
                                       case validateRequestLength(Stream2) of
                                          ok ->
                                             case flushStreamWindowUpdates(StreamId, State2) of
                                                {ok, State3} ->
                                                   case dispatchRequest(StreamId, State3) of
                                                      {ok, State4} -> applyFrames(Rest, State4);
                                                      Stop -> Stop
                                                   end;
                                                {error, SockReason, State3} ->
                                                   {stop, {socket_error, SockReason}, State3}
                                             end;
                                          {error, _} ->
                                             State3 = streamError(StreamId, protocol_error, State2),
                                             applyFrames(Rest, State3)
                                       end
                                 end
                           end
                     end
               end
         end
   end.

discardClosedData(Flags, StreamId, Payload, Rest, State0) ->
   FlowBytes = byte_size(Payload),
   ConnWin = maps:get(recv_conn_window, State0),
   case FlowBytes =< ConnWin of
      false ->
         connError(flow_control_error, connection_receive_window_exceeded, State0);
      true ->
         case stripDataPayload(Flags, Payload) of
            {error, Reason} ->
               connError(protocol_error, Reason, State0);
            {ok, _DiscardedBody} ->
               State1 = State0#{recv_conn_window => ConnWin - FlowBytes},
               case replenishConnectionWindow(FlowBytes, State1) of
                  {error, Reason, State2} ->
                     {stop, {socket_error, Reason}, State2};
                  {ok, State2} ->
                     State3 = streamError(StreamId, stream_closed, State2),
                     applyFrames(Rest, State3)
               end
         end
   end.

replenishConnectionWindow(0, State) ->
   {ok, State};
replenishConnectionWindow(FlowBytes, State0) ->
   Pending0 = maps:get(wu_conn_pending, State0, 0) + FlowBytes,
   Threshold = maps:get(local_initial_window, State0, ?DEFAULT_WINDOW) div 2,
   case Pending0 >= Threshold of
      true ->
         case wsNet:send(maps:get(socket, State0),
            wsHttp2Frame:windowUpdateFrame(0, Pending0)) of
            ok ->
               {ok, queueConnCredit(Pending0, State0#{wu_conn_pending => 0})};
            {error, Reason} ->
               {error, Reason, State0#{wu_conn_pending => Pending0}}
         end;
      false ->
         {ok, State0#{wu_conn_pending => Pending0}}
   end.

%% 累计到半个初始窗口再发 WINDOW_UPDATE；请求 END_STREAM 时冲掉余量。
replenishReceiveWindows(_StreamId, 0, State) ->
   {ok, State};
replenishReceiveWindows(StreamId, FlowBytes, State0) ->
   Streams = maps:get(streams, State0),
   case maps:get(StreamId, Streams, undefined) of
      undefined ->
         replenishConnectionWindow(FlowBytes, State0);
      Stream ->
         StreamPending = maps:get(wu_pending, Stream, 0) + FlowBytes,
         ConnPending = maps:get(wu_conn_pending, State0, 0) + FlowBytes,
         Threshold = maps:get(local_initial_window, State0, ?DEFAULT_WINDOW) div 2,
         State1 = State0#{
            wu_conn_pending => ConnPending,
            streams => Streams#{StreamId := Stream#{wu_pending => StreamPending}}
         },
         case StreamPending >= Threshold orelse ConnPending >= Threshold of
            true -> flushWindowUpdates(StreamId, State1);
            false -> {ok, State1}
         end
   end.

flushStreamWindowUpdates(StreamId, State) ->
   %% END_STREAM 前把尚未宣布的接收窗口 credit 冲掉。写失败意味着
   %% connection transport 已不可可靠使用，绝不能吞错后继续启动 handler。
   flushWindowUpdates(StreamId, State).

flushWindowUpdates(StreamId, State0) ->
   Streams = maps:get(streams, State0),
   {StreamPending, Streams1} = case maps:get(StreamId, Streams, undefined) of
      undefined ->
         {0, Streams};
      Stream ->
         P = maps:get(wu_pending, Stream, 0),
         {P, Streams#{StreamId := Stream#{wu_pending => 0}}}
   end,
   ConnPending = maps:get(wu_conn_pending, State0, 0),
   State1 = State0#{streams => Streams1, wu_conn_pending => 0},
   Frames =
      case {ConnPending > 0, StreamPending > 0} of
         {true, true} ->
            [wsHttp2Frame:windowUpdateFrame(0, ConnPending),
             wsHttp2Frame:windowUpdateFrame(StreamId, StreamPending)];
         {true, false} ->
            [wsHttp2Frame:windowUpdateFrame(0, ConnPending)];
         {false, true} ->
            [wsHttp2Frame:windowUpdateFrame(StreamId, StreamPending)];
         {false, false} ->
            []
      end,
   case Frames of
      [] ->
         {ok, State1};
      _ ->
         case wsNet:send(maps:get(socket, State1), Frames) of
            {error, Reason} ->
               {error, Reason, restoreWuPending(StreamId, StreamPending, ConnPending, State0)};
            ok ->
               State2 = case ConnPending > 0 of
                  true -> queueConnCredit(ConnPending, State1);
                  false -> State1
               end,
               {ok, addStreamRecvCredit(StreamId, StreamPending, State2)}
         end
   end.

restoreWuPending(StreamId, StreamPending, ConnPending, State0) ->
   Streams = maps:get(streams, State0),
   Streams1 = case maps:get(StreamId, Streams, undefined) of
      undefined -> Streams;
      Stream -> Streams#{StreamId := Stream#{wu_pending => StreamPending}}
   end,
   State0#{streams => Streams1, wu_conn_pending => ConnPending}.

addStreamRecvCredit(_StreamId, 0, State) ->
   State;
addStreamRecvCredit(StreamId, Credit, State) ->
   Credits0 = maps:get(pending_stream_credits, State, #{}),
   Pending = maps:get(StreamId, Credits0, 0) + Credit,
   State#{pending_stream_credits => Credits0#{StreamId => Pending}}.

%% 本批 recv 里已经宣布给对端的窗口，要等这批帧全部校验完再加回本地计数。
queueConnCredit(FlowBytes, State) ->
   State#{pending_conn_credit => maps:get(pending_conn_credit, State, 0) + FlowBytes}.

applyRecvCredit(State0) ->
   Conn = maps:get(recv_conn_window, State0) + maps:get(pending_conn_credit, State0, 0),
   Credits = maps:get(pending_stream_credits, State0, #{}),
   Streams0 = maps:get(streams, State0),
   %% 只更新本批真正收到 WINDOW_UPDATE credit 的 stream；旧实现 maps:map
   %% 每个 recv batch 都扫描所有打开 stream，高并发 multiplexing 下是 O(N) 固定成本。
   Streams = maps:fold(fun(StreamId, Credit, Acc) ->
      case maps:get(StreamId, Acc, undefined) of
         undefined ->
            Acc;
         Stream ->
            Acc#{StreamId := Stream#{
               recv_window => maps:get(recv_window, Stream, ?DEFAULT_WINDOW) + Credit
            }}
      end
   end, Streams0, Credits),
   State0#{
      recv_conn_window => Conn,
      pending_conn_credit => 0,
      pending_stream_credits => #{},
      streams => Streams
   }.

validateRequestLength(Stream) ->
   ContentLength = maps:get(content_length, Stream, undefined),
   BodySize = maps:get(body_size, Stream),
   case ContentLength of
      undefined -> ok;
      BodySize -> ok;
      _ -> {error, content_length_mismatch}
   end.

dispatchRequest(StreamId, State0) ->
   Streams = maps:get(streams, State0),
   Stream0 = maps:get(StreamId, Streams),
   case maps:get(handler_ref, Stream0, undefined) of
      undefined ->
         StreamA = Stream0,
         Req0 = maps:get(req, StreamA),
         Body = case maps:get(body_acc, StreamA) of
            [] -> <<>>;
            [One] -> One;
            Acc -> iolist_to_binary(lists:reverse(Acc))
         end,
         Req = Req0#wsReq{body = Body},
         WsMod = maps:get(ws_mod, State0),
         Parent = self(),
         {Pid, MonitorRef} = spawn_monitor(fun() ->
            runHandlerWorker(Parent, StreamId, WsMod, Req)
         end),
         Stream1 = StreamA#{
            req => Req,
            body_acc => [],
            remote_closed => true,
            handler_pid => Pid,
            handler_ref => MonitorRef
         },
         {ok, State0#{streams => Streams#{StreamId := Stream1}}};
      _ ->
         %% END_STREAM has already dispatched this request.
         {ok, State0}
   end.

armRequestTimer(StreamId, Stream, State) ->
   Token = make_ref(),
   TimerRef = erlang:send_after(maps:get(request_timeout, State), self(), {h2_request_timeout, StreamId, Token}),
   Stream#{request_timer => TimerRef, request_token => Token}.

cancelRequestTimer(#{request_timer := TimerRef} = Stream) ->
   _ = erlang:cancel_timer(TimerRef),
   maps:remove(request_token, maps:remove(request_timer, Stream));
cancelRequestTimer(Stream) ->
   Stream.

handleRequestTimeout(StreamId, Token, State) ->
   case maps:get(StreamId, maps:get(streams, State), undefined) of
      #{request_token := Token} ->
         ?wsWarn("HTTP/2 stream timeout stream=~p", [StreamId]),
         {ok, streamError(StreamId, cancel, State)};
      _ ->
         {ok, State}
   end.

handleSettingsTimeout(Token, State) ->
   case {maps:get(settings_ack_token, State, undefined), maps:get(expect_settings_ack, State, false)} of
      {Token, true} ->
         connError(settings_timeout, settings_ack_timeout, State);
      _ ->
         {ok, State}
   end.

hasOpenStreams(State) ->
   map_size(maps:get(streams, State, #{})) > 0.

idleClose(State) ->
   Last = maps:get(last_client_stream, State, 0),
   _ = wsNet:send(maps:get(socket, State), wsHttp2Frame:goawayFrame(Last, no_error)),
   State#{goaway => true}.

runHandlerWorker(Parent, StreamId, WsMod, Req) ->
   Response0 = callHandler(WsMod, Req#wsReq.method, Req#wsReq.path, Req),
   Response = compressHandlerResponse(Response0, Req),
   case Response of
      {chunk, Headers, Initial} ->
         Token = make_ref(),
         Parent ! {h2_stream_start, StreamId, self(), Token, Req, Headers, Initial},
         case waitChunkAck(Token) of
            ok -> h2ChunkWorkerLoop(Parent, StreamId);
            _ -> ok
         end;
      _ ->
         Parent ! {h2_response, StreamId, self(), Req, Response}
   end.

%% gzip/deflate 在 stream worker 里做，避免大响应堵住连接进程上的其它流。
compressHandlerResponse({response, Code, Headers0, Body0}, Req) ->
   Method = Req#wsReq.method,
   {Body, Headers} = wsHttp:tryCompressResponse(
      Body0, Headers0, Req#wsReq.headers, Code, Method),
   {response, Code, Headers, Body};
compressHandlerResponse(Other, _Req) ->
   Other.

h2ChunkWorkerLoop(Parent, StreamId) ->
   receive
      {chunk, close} ->
         Parent ! {h2_stream_close, StreamId, self(), false};
      {chunk, close, From} ->
         Parent ! {h2_stream_close, StreamId, self(), From};
      {chunk, Data} ->
         Token = make_ref(),
         Parent ! {h2_stream_chunk, StreamId, self(), Token, Data, false},
         case waitChunkAck(Token) of
            ok -> h2ChunkWorkerLoop(Parent, StreamId);
            _ -> ok
         end;
      {chunk, Data, From} ->
         Token = make_ref(),
         Parent ! {h2_stream_chunk, StreamId, self(), Token, Data, From},
         case waitChunkAck(Token) of
            ok -> h2ChunkWorkerLoop(Parent, StreamId);
            _ -> ok
         end
   end.

waitChunkAck(Token) ->
   receive
      {h2_chunk_ack, Token, Result} -> Result
   end.

handleStreamStart(StreamId, WorkerPid, Token, Req, Headers0, Initial0, State0) ->
   case getWorkerStream(StreamId, WorkerPid, State0) of
      {error, State} ->
         WorkerPid ! {h2_chunk_ack, Token, closed},
         {ok, State};
      {ok, Stream0, State} ->
         Method = Req#wsReq.method,
         Headers = normalizeResponseHeaders(Headers0, []),
         H2Headers = [{<<":status">>, <<"200">>} | Headers],
         case responseHeadersAllowed(headerListSize(H2Headers), State) of
            false ->
               %% streaming response 也必须遵守与普通响应相同的 header-list
               %% 上限；并且应在 HPACK 编码前拒绝，避免为注定丢弃的超大头做压缩。
               WorkerPid ! {h2_chunk_ack, Token, {error, headers}},
               {ok, streamError(StreamId, internal_error, State)};
            true ->
               Tx0 = maps:get(tx_hpack, State),
               {Block, Tx} = wsHpack:encodeLower(H2Headers, Tx0),
               HeadOnly = Method =:= 'HEAD',
               HFrames = wsHttp2Frame:headersFrames(Block, StreamId, maps:get(peer_max_frame, State), HeadOnly),
               case wsNet:send(maps:get(socket, State), HFrames) of
                  {error, Reason} ->
                     WorkerPid ! {h2_chunk_ack, Token, {error, Reason}},
                     {stop, {socket_error, Reason}, State};
                  ok when HeadOnly ->
                     WorkerPid ! {h2_chunk_ack, Token, closed},
                     {ok, dropStream(StreamId, State#{tx_hpack => Tx})};
                  ok ->
                     Initial = iolist_to_binary(Initial0),
                     Stream1 = Stream0#{
                        response_started => true,
                        streaming => true,
                        pending_send => <<>>,
                        pending_end_stream => false,
                        pending_ack => undefined
                     },
                     State1 = State#{tx_hpack => Tx, streams => (maps:get(streams, State))#{StreamId := Stream1}},
                     case Initial of
                        <<>> ->
                           WorkerPid ! {h2_chunk_ack, Token, ok},
                           {ok, State1};
                        _ ->
                           queueStreamChunk(StreamId, WorkerPid, Token, Initial, false, State1)
                     end
               end
         end
   end.

handleStreamChunk(StreamId, WorkerPid, Token, Data0, From, State0) ->
   case getWorkerStream(StreamId, WorkerPid, State0) of
      {error, State} ->
         maybeReplyChunkFrom(From, {error, closed}),
         WorkerPid ! {h2_chunk_ack, Token, closed},
         {ok, State};
      {ok, #{streaming := true, pending_send := <<>>}, State} ->
         Data = iolist_to_binary(Data0),
         case Data of
            <<>> ->
               maybeReplyChunkFrom(From, ok),
               WorkerPid ! {h2_chunk_ack, Token, ok},
               {ok, State};
            _ ->
               queueStreamChunk(StreamId, WorkerPid, Token, Data, From, State)
         end;
      {ok, _Stream, State} ->
         maybeReplyChunkFrom(From, {error, busy}),
         WorkerPid ! {h2_chunk_ack, Token, {error, busy}},
         {ok, State}
   end.

handleStreamClose(StreamId, WorkerPid, From, State0) ->
   case getWorkerStream(StreamId, WorkerPid, State0) of
      {error, State} ->
         maybeReplyChunkFrom(From, {error, closed}),
         {ok, State};
      {ok, #{streaming := true, pending_send := <<>>}, State} ->
         Frame = wsHttp2Frame:frame(data, StreamId, <<>>, ?END_STREAM),
         case wsNet:send(maps:get(socket, State), Frame) of
            ok ->
               maybeReplyChunkFrom(From, ok),
               {ok, dropStream(StreamId, State)};
            {error, Reason} ->
               maybeReplyChunkFrom(From, {error, closed}),
               {stop, {socket_error, Reason}, State}
         end;
      {ok, _Stream, State} ->
         maybeReplyChunkFrom(From, {error, busy}),
         {ok, State}
   end.

getWorkerStream(StreamId, WorkerPid, State) ->
   case maps:get(StreamId, maps:get(streams, State), undefined) of
      #{handler_pid := WorkerPid} = Stream -> {ok, Stream, State};
      _ -> {error, State}
   end.

queueStreamChunk(StreamId, WorkerPid, Token, Data, From, State0) ->
   Streams = maps:get(streams, State0),
   Stream = maps:get(StreamId, Streams),
   Stream1 = Stream#{pending_send => Data, pending_end_stream => false, pending_ack => {WorkerPid, Token, From}},
   State1 = State0#{streams => Streams#{StreamId := Stream1}},
   case flushPending(StreamId, State1) of
      {ok, State2} -> {ok, State2};
      {error, Code, Reason} -> connError(Code, Reason, State1)
   end.

completePendingAck(undefined, _Result) ->
   ok;
completePendingAck({WorkerPid, Token, From}, Result) ->
   maybeReplyChunkFrom(From, Result),
   WorkerPid ! {h2_chunk_ack, Token, Result},
   ok.

maybeReplyChunkFrom(false, _Result) ->
   ok;
maybeReplyChunkFrom(From, Result) when is_pid(From) ->
   From ! {self(), Result},
   ok;
maybeReplyChunkFrom(_From, _Result) ->
   ok.

failStreamPendingAck(Stream) ->
   case maps:get(pending_ack, Stream, undefined) of
      undefined -> ok;
      Ack -> completePendingAck(Ack, {error, closed})
   end.

%% @doc Apply a completed stream worker response in the owning connection process.
%% HPACK encoder and flow-control state are connection-scoped, therefore only
%% the connection process is allowed to encode/send the response.
handleResponse(StreamId, WorkerPid, Req, Response, State0) ->
   Streams = maps:get(streams, State0),
   case maps:get(StreamId, Streams, undefined) of
      #{handler_pid := WorkerPid, handler_ref := MonitorRef} = Stream ->
         erlang:demonitor(MonitorRef, [flush]),
         Stream1 = maps:remove(handler_ref, maps:remove(handler_pid, Stream)),
         State1 = State0#{streams => Streams#{StreamId := Stream1}},
         sendHandlerResponse(StreamId, Response, Req, State1);
      _ ->
         %% Stream may have been reset/closed while the worker was running.
         {ok, State0}
   end.

%% @doc Convert an abnormal worker exit into a stream-local 500 response.
handleWorkerDown(MonitorRef, Reason, State0) ->
   case findWorkerStream(MonitorRef, maps:get(streams, State0)) of
      none ->
         {ok, State0};
      {_StreamId, _Stream} when Reason =:= normal ->
         %% Normally the response message is delivered before DOWN. If the stream
         %% is still present here, keep it until the response message is handled.
         {ok, State0};
      {StreamId, Stream} ->
         Req = maps:get(req, Stream),
         ?wsErr("HTTP/2 stream worker down stream=~p reason=~p", [StreamId, Reason]),
         Streams = maps:get(streams, State0),
         Stream1 = maps:remove(handler_ref, maps:remove(handler_pid, Stream)),
         State1 = State0#{streams => Streams#{StreamId := Stream1}},
         sendHandlerResponse(StreamId, {response, 500, [], <<"Internal server error">>}, Req, State1)
   end.

findWorkerStream(Ref, Streams) when is_map(Streams) ->
   %% DOWN 是低频/竞态路径，但无需先把整个 streams map 复制成 list。
   %% iterator 还能在命中 monitor ref 后立即停止。
   findWorkerStreamIter(Ref, maps:iterator(Streams)).

findWorkerStreamIter(Ref, Iter) ->
   case maps:next(Iter) of
      none ->
         none;
      {StreamId, #{handler_ref := Ref} = Stream, _Next} ->
         {StreamId, Stream};
      {_StreamId, _Stream, Next} ->
         findWorkerStreamIter(Ref, Next)
   end.

callHandler(WsMod, Method, Path, Req) ->
   try WsMod:handle(Method, Path, Req) of
      {ok, Headers, {file, Filename}} -> {file, 200, Headers, Filename, []};
      {ok, Headers, {file, Filename, Range}} -> {file, 200, Headers, Filename, Range};
      {ok, Headers, Body} -> {response, 200, Headers, Body};
      {ok, Body} -> {response, 200, [], Body};
      {HttpCode, Headers, {file, Filename}}
         when is_integer(HttpCode), HttpCode >= 200, HttpCode =< 999 ->
         {file, HttpCode, Headers, Filename, []};
      {HttpCode, Headers, {file, Filename, Range}}
         when is_integer(HttpCode), HttpCode >= 200, HttpCode =< 999 ->
         {file, HttpCode, Headers, Filename, Range};
      {HttpCode, Headers, Body}
         when is_integer(HttpCode), HttpCode >= 200, HttpCode =< 999 ->
         {response, HttpCode, Headers, Body};
      {HttpCode, Body}
         when is_integer(HttpCode), HttpCode >= 200, HttpCode =< 999 ->
         {response, HttpCode, [], Body};
      {chunk, Headers} ->
         {chunk, Headers, <<>>};
      {chunk, Headers, Initial} ->
         {chunk, Headers, Initial};
      {wsUpgrade, _Headers} ->
         {response, 501, [], <<"WebSocket over HTTP/2 not enabled">>};
      Unexpected ->
         ?wsErr("HTTP/2 handler unexpected return req=~p ret_shape=~p",
            [requestLogInfo(Req), returnShape(Unexpected)]),
         {response, 500, [], <<"Internal server error">>}
   catch
      Class:Reason:Stacktrace ->
         ?wsErr("HTTP/2 handler exception req=~p ~p:~P stack=~P",
            [requestLogInfo(Req), Class, Reason, 8, Stacktrace, 12]),
         {response, 500, [], <<"Internal server error">>}
   end.

requestLogInfo(#wsReq{method = Method, path = Path, version = Version, headers = Headers, body = Body}) ->
   {Method, Path, Version, length(Headers), safeBodySize(Body)}.

safeBodySize(Body) ->
   try iolist_size(Body) catch _:_ -> unknown end.

returnShape(Term) when is_binary(Term) -> {binary, byte_size(Term)};
returnShape(Term) when is_list(Term) -> list;
returnShape(Term) when is_map(Term) -> {map, map_size(Term)};
returnShape(Term) when is_tuple(Term), tuple_size(Term) > 0 ->
   case element(1, Term) of
      Tag when is_atom(Tag) -> {tuple, tuple_size(Term), Tag};
      _ -> {tuple, tuple_size(Term)}
   end;
returnShape(Term) when is_atom(Term) -> Term;
returnShape(Term) when is_integer(Term) -> integer;
returnShape(Term) when is_float(Term) -> float;
returnShape(_) -> other.

sendHandlerResponse(StreamId, {file, Code, Headers, Filename, Range}, Req, State) ->
   Method = Req#wsReq.method,
   case wsUtil:fileSize(Filename) of
      {error, _} ->
         sendResponse(StreamId, 500, [], <<"Internal server error">>, Method, State);
      Size ->
         case fileSpan(Size, Range) of
            invalid_range ->
               RangeHeader = [{<<"content-range">>, wsUtil:encodeRange(invalid_range, Size)}],
               sendResponse(StreamId, 416, Headers ++ RangeHeader, <<>>, Method, State);
            {Status, Offset, Length, Extra} ->
               sendFileResponse(StreamId, statusOr(Code, Status), Headers ++ Extra,
                  Filename, Offset, Length, Method, State)
         end
   end;
sendHandlerResponse(StreamId, {response, Code, Headers, Body}, Req, State) ->
   %% 压缩已在 stream worker 里完成。
   sendResponse(StreamId, Code, Headers, Body, Req#wsReq.method, State).

statusOr(Code, 200) -> Code;
statusOr(_Code, Status) -> Status.

fileSpan(Size, []) -> {200, 0, Size, []};
fileSpan(Size, {0, 0}) -> {200, 0, Size, []};
fileSpan(Size, Range) ->
   case wsUtil:normalizeRange(Range, Size) of
      undefined -> {200, 0, Size, []};
      {Offset, Length} ->
         {206, Offset, Length, [{<<"content-range">>, wsUtil:encodeRange({Offset, Length}, Size)}]};
      invalid_range -> invalid_range
   end.

%% 文件按当前发送窗口逐段 pread，避免把整个文件读进连接进程。
sendFileResponse(StreamId, Code, Headers, Filename, Offset, Length, Method, State0) ->
   NoBody = Method =:= 'HEAD' orelse Length =:= 0
      orelse Code =:= 204 orelse Code =:= 205 orelse Code =:= 304,
   case NoBody of
      true ->
         sendResponse(StreamId, Code, Headers, <<>>, Length, Method, State0);
      false ->
         case file:open(Filename, [read, raw, binary]) of
            {error, _} ->
               sendResponse(StreamId, 500, [], <<"Internal server error">>, Method, State0);
            {ok, Fd} ->
               case sendHeaderBlock(StreamId, Code, Headers, Length, false, State0) of
                  {error, headers, State1} ->
                     _ = file:close(Fd),
                     {ok, streamError(StreamId, internal_error, State1)};
                  {stop, Reason, State1} ->
                     _ = file:close(Fd),
                     {stop, Reason, State1};
                  {ok, Tx, State1} ->
                     Streams = maps:get(streams, State1),
                     Stream = maps:get(StreamId, Streams),
                     State2 = State1#{
                        tx_hpack => Tx,
                        streams => Streams#{StreamId := Stream#{
                           pending_send => <<>>,
                           pending_file => {Fd, Offset, Length},
                           pending_end_stream => true,
                           pending_ack => undefined,
                           response_started => true
                        }}
                     },
                     case flushPending(StreamId, State2) of
                        {ok, State3} -> {ok, State3};
                        {error, Code2, Reason2} -> connError(Code2, Reason2, State2)
                     end
               end
         end
   end.

sendResponse(StreamId, Code, Headers0, Body0, Method, State0) ->
   DeclaredSize = iolist_size(Body0),
   Informational = is_integer(Code) andalso Code >= 100 andalso Code < 200,
   NoBody = Method =:= 'HEAD' orelse Code =:= 204 orelse Code =:= 205
      orelse Code =:= 304 orelse Informational,
   %% HEAD/no-body status 只需要声明长度，不应为了随后丢弃而复制整个 iolist。
   Body = case NoBody of
      true -> <<>>;
      false when is_binary(Body0) -> Body0;
      false -> iolist_to_binary(Body0)
   end,
   sendResponse(StreamId, Code, Headers0, Body, DeclaredSize, Method, State0).

sendResponse(StreamId, Code, Headers0, Body, DeclaredSize, Method, State0) ->
   Informational = is_integer(Code) andalso Code >= 100 andalso Code < 200,
   SendBody = not (Method =:= 'HEAD' orelse Code =:= 204 orelse Code =:= 205 orelse Code =:= 304 orelse Informational),
   WireBody = case SendBody of true -> Body; false -> <<>> end,
   %% 1xx 不能带 END_STREAM。handler 只返回信息性状态时，流保持打开，
   %% 由 stream 超时负责收尾，避免发出畸形的最终 HEADERS。
   EndOnHeaders = (not Informational) andalso WireBody =:= <<>>,
   case sendHeaderBlock(StreamId, Code, Headers0, DeclaredSize, EndOnHeaders, State0) of
      {error, headers, State1} ->
         {ok, streamError(StreamId, internal_error, State1)};
      {stop, _, _} = Stop ->
         Stop;
      {ok, Tx, State1} when Informational ->
         {ok, State1#{tx_hpack => Tx}};
      {ok, Tx, State1} when EndOnHeaders ->
         {ok, dropStream(StreamId, State1#{tx_hpack => Tx})};
      {ok, Tx, State1} ->
         Streams = maps:get(streams, State1),
         Stream = maps:get(StreamId, Streams),
         State2 = State1#{
            tx_hpack => Tx,
            streams => Streams#{StreamId := Stream#{
               pending_send => WireBody,
               pending_end_stream => true,
               pending_ack => undefined,
               response_started => true
            }}
         },
         case flushPending(StreamId, State2) of
            {ok, State3} -> {ok, State3};
            {error, Code2, Reason2} -> connError(Code2, Reason2, State2)
         end
   end.

sendHeaderBlock(StreamId, Code, Headers0, DeclaredSize, EndOnHeaders, State0) ->
   %% content-length 使用声明长度。HEAD 与 GET 在这里规则相同，
   %% 是否真正发送 body 由调用方决定。
   Headers1 = responseHeaders(Code, Headers0, DeclaredSize, 'GET'),
   H2Headers = [{<<":status">>, integer_to_binary(Code)} | Headers1],
   case responseHeadersAllowed(headerListSize(H2Headers), State0) of
      false ->
         {error, headers, State0};
      true ->
         Tx0 = maps:get(tx_hpack, State0),
         {Block, Tx} = wsHpack:encodeLower(H2Headers, Tx0),
         HFrames = wsHttp2Frame:headersFrames(Block, StreamId, maps:get(peer_max_frame, State0), EndOnHeaders),
         case wsNet:send(maps:get(socket, State0), HFrames) of
            {error, Reason} ->
               {stop, {socket_error, Reason}, State0};
            ok ->
               {ok, Tx, State0}
         end
   end.

responseHeadersAllowed(Size, State) ->
   LocalMax = maps:get(max_header, State),
   PeerMax = maps:get(peer_max_header_list, State, infinity),
   Size =< LocalMax andalso
      case PeerMax of
         infinity -> true;
         Max when is_integer(Max), Max >= 0 -> Size =< Max
      end.

responseHeaders(Code, Headers0, BodySize, Method) ->
   Headers = normalizeResponseHeaders(Headers0, []),
   case Code of
      C when C >= 100, C < 200 -> Headers;
      204 -> Headers;
      205 -> [{<<"content-length">>, <<"0">>} | Headers];
      304 -> Headers;
      _ when Method =:= 'HEAD' -> [{<<"content-length">>, integer_to_binary(BodySize)} | Headers];
      _ -> [{<<"content-length">>, integer_to_binary(BodySize)} | Headers]
   end.

normalizeResponseHeaders([], Acc) ->
   lists:reverse(Acc);
normalizeResponseHeaders([{Name0, Value0} | Rest], Acc) ->
   %% 已是小写的 binary 不分配；handler 常给 <<"content-type">> 这类字面量。
   Name = wsUtil:ensureLower(toBinary(Name0)),
   %% 框架自管/禁止字段先判名字：被丢弃的字段无需再转换和扫描 value。
   case Name of
      <<"content-length">> ->
         normalizeResponseHeaders(Rest, Acc);
      _ ->
         case isHopByHop(Name) of
            true ->
               normalizeResponseHeaders(Rest, Acc);
            false ->
               Value = toBinary(Value0),
               case validMethod(Name) andalso validHeaderValue(Value) of
                  true ->
                     normalizeResponseHeaders(Rest, [{Name, Value} | Acc]);
                  false ->
                     %% Handler-generated malformed fields must never corrupt the H2 stream.
                     ?wsWarn("ignore invalid HTTP/2 response header name=~p", [Name]),
                     normalizeResponseHeaders(Rest, Acc)
               end
         end
   end.

resumePending(State) ->
   flushAllPending(State#{flush_scheduled => false}).

flushAllPending(State0) ->
   %% Connection WINDOW_UPDATE / peer SETTINGS only need to revisit streams
   %% that actually have buffered DATA/file bytes waiting for send credit.
   %% 直接 fold 原 map，避免 maps:keys/1 为每次窗口更新分配临时 id list。
   maps:fold(fun(Id, _True, Acc) ->
      case Acc of
         {ok, State} -> flushPending(Id, State);
         Other -> Other
      end
   end, {ok, State0}, maps:get(send_pending_streams, State0, #{})).

flushPending(StreamId, State0) ->
   StateA = markSendPending(StreamId, State0),
   Streams = maps:get(streams, StateA),
   case maps:get(StreamId, Streams, undefined) of
      undefined -> {ok, clearSendPending(StreamId, StateA)};
      _Stream ->
         case prepareSendBuffer(StreamId, StateA) of
            {error, Reason} -> {error, internal_error, Reason};
            {ok, State1} ->
               case maps:get(StreamId, maps:get(streams, State1), undefined) of
                  undefined -> {ok, State1};
                  Stream1 ->
                     case maps:get(pending_send, Stream1, <<>>) of
                        <<>> -> maybeFinishStream(StreamId, State1);
                        Bin -> flushPendingLoop(StreamId, Bin, State1, false)
                     end
               end
         end
   end.

flushPendingLoop(StreamId, Pending, State0, SentAny) ->
   Streams = maps:get(streams, State0),
   Stream = maps:get(StreamId, Streams),
   ConnWin = maps:get(send_conn_window, State0),
   StreamWin = maps:get(send_window, Stream),
   MaxFrame = maps:get(peer_max_frame, State0),
   MinWindow = erlang:min(ConnWin, StreamWin),
   WindowBytes = erlang:max(0, erlang:min(byte_size(Pending), MinWindow)),
   Allowed = erlang:min(WindowBytes, ?SEND_BATCH_BYTES),
   case Allowed of
      0 ->
         case SentAny of
            true -> {ok, touchStreamTimer(StreamId, State0)};
            false -> {ok, State0}
         end;
      N ->
         <<Batch:N/binary, Rest/binary>> = Pending,
         EndStream = maps:get(pending_end_stream, Stream, true),
         %% pending_file 的剩余量不含当前 pending_send。只有缓冲区和文件都
         %% 发完，最后一个 batch 的最后一帧才能带 END_STREAM。
         MoreFile = fileRemaining(Stream) > 0,
         EndBatch = Rest =:= <<>> andalso EndStream andalso not MoreFile,
         Frames = wsHttp2Frame:dataFrames(Batch, StreamId, MaxFrame, EndBatch),
         %% 一个 flow-control burst 一次 send，默认 64KB 窗口由约4次发送降为1次。
         case wsNet:send(maps:get(socket, State0), Frames) of
            {error, Reason} ->
               completePendingAck(maps:get(pending_ack, Stream, undefined), {error, closed}),
               {error, internal_error, {socket_error, Reason}};
            ok ->
               Stream1 = Stream#{send_window => StreamWin - N, pending_send => Rest},
               State1 = State0#{
                  send_conn_window => ConnWin - N,
                  streams => Streams#{StreamId := Stream1}
               },
               case Rest of
                  <<>> when EndStream ->
                     case fileRemaining(Stream1) of
                        Left when Left > 0 ->
                           %% 一轮最多推进一个 SEND_BATCH_BYTES 文件块，然后
                           %% 让出 connection owner；避免单个大文件独占 H2。
                           {ok, scheduleFlush(touchStreamTimer(StreamId, State1))};
                        _ ->
                           completePendingAck(maps:get(pending_ack, Stream1, undefined), ok),
                           {ok, dropStream(StreamId, State1)}
                     end;
                  <<>> ->
                     completePendingAck(maps:get(pending_ack, Stream1, undefined), ok),
                     Streams1 = maps:get(streams, State1),
                     Stream2 = maps:get(StreamId, Streams1),
                     State2 = State1#{streams => Streams1#{StreamId := Stream2#{
                        pending_ack => undefined,
                        pending_end_stream => false
                     }}},
                     {ok, clearSendPending(StreamId, touchStreamTimer(StreamId, State2))};
                  _ ->
                     %% pending_send 仍有数据时不要在当前 mailbox turn 递归
                     %% 吃完整个大响应。保留 pending 状态并合并调度下一轮。
                     {ok, scheduleFlush(State1)}
               end
         end
   end.

scheduleFlush(#{flush_scheduled := true} = State) ->
   State;
scheduleFlush(State) ->
   self() ! h2_flush_pending,
   State#{flush_scheduled => true}.

stripHeadersPayload(Flags, StreamId, Payload0) ->
   case stripPadding(Flags, Payload0) of
      {error, _} = Error -> Error;
      {ok, Payload1} when Flags band ?PRIORITY =/= 0 ->
         case wsHttp2Frame:priorityFields(Payload1) of
            {ok, _Exclusive, StreamId, _Weight, _Rest} -> {error, priority_self_dependency};
            {ok, _Exclusive, _Dep, _Weight, Rest} -> {ok, Rest};
            _ -> {error, bad_priority}
         end;
      {ok, Payload1} -> {ok, Payload1}
   end.

stripDataPayload(Flags, Payload) ->
   stripPadding(Flags, Payload).

stripPadding(Flags, Payload) when Flags band ?PADDED =:= 0 ->
   {ok, Payload};
stripPadding(_Flags, <<PadLen:8, Rest/binary>>) ->
   case byte_size(Rest) >= PadLen of
      false -> {error, bad_padding};
      true ->
         DataLen = byte_size(Rest) - PadLen,
         <<Data:DataLen/binary, _Padding:PadLen/binary>> = Rest,
         {ok, Data}
   end;
stripPadding(_Flags, _) ->
   {error, bad_padding}.

requestFromHeaders(Headers, State) ->
   case parseHeaderList(Headers, #{}, [], pseudo, #{}) of
      {error, _} = Error -> Error;
      {ok, Pseudo, Regular, Seen} ->
         MethodBin = maps:get(<<":method">>, Pseudo, undefined),
         Protocol = maps:get(<<":protocol">>, Pseudo, undefined),
         case {MethodBin, Protocol} of
            {undefined, _} ->
               {error, missing_method};
            {Method, _} when not is_binary(Method); Method =:= <<>> ->
               {error, invalid_method};
            {Method, _} ->
               case validMethod(Method) of
                  false ->
                     {error, invalid_method};
                  true when Protocol =/= undefined ->
                     {error, extended_connect_not_enabled};
                  true ->
                     case validateScheme(maps:get(<<":scheme">>, Pseudo, undefined), maps:get(scheme, State), Method) of
                        ok -> buildRequest(Method, Pseudo, Regular, Seen, State);
                        {error, _} = SchemeErr -> SchemeErr
                     end
               end
         end
   end.

parseHeaderList([], Pseudo, Regular, _Phase, Seen) ->
   {ok, Pseudo, lists:reverse(Regular), Seen};
parseHeaderList([{Name0, Value0} | Rest], Pseudo, Regular, Phase, Seen) ->
   Name = toBinary(Name0),
   Value = toBinary(Value0),
   %% 零分配检查小写，替代 Name =:= toLowerStr(Name)（每次分配一份拷贝）。
   case wsUtil:isLowerAscii(Name) of
      false ->
         {error, uppercase_header_name};
      true ->
         case {Name, validHeaderValue(Value)} of
            {<<>>, _} ->
               {error, empty_header_name};
            {_, false} ->
               {error, invalid_header_value};
            {_, true} ->
               case Name of
                  <<":", _/binary>> when Phase =:= regular ->
                     {error, pseudo_header_after_regular};
                  <<":", _/binary>> ->
                     case allowedRequestPseudo(Name) andalso not maps:is_key(Name, Seen) of
                        false -> {error, {bad_pseudo_header, Name}};
                        true -> parseHeaderList(Rest, Pseudo#{Name => Value}, Regular, pseudo, Seen#{Name => true})
                     end;
                  _ ->
                     %% Value 已在本层 validHeaderValue/1 校验过；普通字段
                     %% 不要在 validRegularHeader/2 里再完整扫描一遍 value。
                     case validRegularHeaderValidated(Name, Value) of
                        false ->
                           {error, {bad_header, Name}};
                        true ->
                           case noteRequestHeader(Name, Value, Seen) of
                              {ok, Seen1} ->
                                 parseHeaderList(Rest, Pseudo, [{Name, Value} | Regular], regular, Seen1);
                              {error, _} = Error ->
                                 Error
                           end
                     end
               end
         end
   end.

allowedRequestPseudo(<<":method">>) -> true;
allowedRequestPseudo(<<":scheme">>) -> true;
allowedRequestPseudo(<<":authority">>) -> true;
allowedRequestPseudo(<<":path">>) -> true;
allowedRequestPseudo(<<":protocol">>) -> true;
allowedRequestPseudo(_) -> false.

%% 通用入口用于 trailer 等尚未校验 value 的路径。
validRegularHeader(Name, Value) ->
   validHeaderValue(Value) andalso validRegularHeaderValidated(Name, Value).

%% request header 主解析路径已经在外层校验过 value；这里只检查
%% field-name / hop-by-hop / TE 特例，避免每个普通 header 重扫 value。
validRegularHeaderValidated(Name, Value) ->
   case validHeaderName(Name) andalso not isHopByHop(Name) of
      false ->
         false;
      true when Name =:= <<"te">> ->
         %% TE is the one connection-specific exception in HTTP/2.
         wsUtil:headerNameEq(string:trim(Value), <<"trailers">>);
      true ->
         true
   end.

validHeaderName(Name) ->
   %% field-name = token。parseHeaderList/5 另外强制了小写。
   validMethod(Name).

validHeaderValue(<<>>) ->
   true;
validHeaderValue(Value) ->
   %% RFC 9113 §8.2.1 minimum validation.
   First = binary:first(Value),
   Last = binary:last(Value),
   First =/= 32 andalso First =/= 9 andalso
   Last =/= 32 andalso Last =/= 9 andalso
   wsUtil:noCtlChars(Value).

isHopByHop(<<"connection">>) -> true;
isHopByHop(<<"proxy-connection">>) -> true;
isHopByHop(<<"keep-alive">>) -> true;
isHopByHop(<<"transfer-encoding">>) -> true;
isHopByHop(<<"upgrade">>) -> true;
isHopByHop(_) -> false.

%% 正常 header 在 parseHeaderList/5 本来就必须逐项走一遍。这里顺手记录
%% 后续构造请求必需的元数据，避免再为 Host / Content-Length 扫描 Regular。
noteRequestHeader(<<"host">>, Value, Seen) ->
   Hosts = maps:get(host_values, Seen, []),
   {ok, Seen#{host_values => [Value | Hosts]}};
noteRequestHeader(<<"content-length">>, Value, Seen) ->
   case parseContentLengthValue(Value) of
      N when is_integer(N) ->
         case maps:get(content_length, Seen, undefined) of
            undefined -> {ok, Seen#{content_length => N}};
            N -> {ok, Seen};
            _Other -> {error, conflicting_content_length}
         end;
      _ ->
         {error, invalid_content_length}
   end;
noteRequestHeader(_Name, _Value, Seen) ->
   {ok, Seen}.

buildRequest(<<"CONNECT">>, Pseudo, Regular, Seen, State) ->
   case {maps:get(<<":authority">>, Pseudo, undefined),
         maps:get(<<":scheme">>, Pseudo, undefined),
         maps:get(<<":path">>, Pseudo, undefined)} of
      {undefined, _, _} -> {error, missing_authority};
      {_Authority, undefined, undefined} ->
         makeRequest(<<"CONNECT">>, Pseudo, Regular, Seen, State);
      _ -> {error, bad_connect_pseudo_headers}
   end;
buildRequest(MethodBin, Pseudo, Regular, Seen, State) ->
   case {maps:get(<<":scheme">>, Pseudo, undefined), maps:get(<<":path">>, Pseudo, undefined)} of
      {undefined, _} -> {error, missing_scheme};
      {_, undefined} -> {error, missing_path};
      {_Scheme, <<>>} -> {error, empty_path};
      {_Scheme, <<"*">>} when MethodBin =:= <<"OPTIONS">> ->
         makeRequest(MethodBin, Pseudo, Regular, Seen, State);
      {_Scheme, <<"*">>} ->
         {error, asterisk_path_requires_options};
      {_Scheme, <<"/", _/binary>>} ->
         makeRequest(MethodBin, Pseudo, Regular, Seen, State);
      _ ->
         {error, invalid_path}
   end.

makeRequest(MethodBin, Pseudo, Regular, Seen, State) ->
   PathQuery = maps:get(<<":path">>, Pseudo, <<>>),
   {Path, Args} = splitPathQuery(PathQuery),
   SchemeBin = maps:get(<<":scheme">>, Pseudo,
      case maps:get(scheme, State) of https -> <<"https">>; _ -> <<"http">> end),
   Authority = maps:get(<<":authority">>, Pseudo, undefined),
   HostHeaders = maps:get(host_values, Seen, []),
   case validateAuthority(Authority, HostHeaders, SchemeBin) of
      {error, _} = Error ->
         Error;
      {ok, Host, Port} ->
         CompatHeaders =
            case {Authority, HostHeaders} of
               {undefined, _} -> Regular;
               {_Auth, []} -> [{<<"host">>, Authority} | Regular];
               {_Auth, _} -> Regular
            end,
         ContentLength = maps:get(content_length, Seen, undefined),
         case ContentLength of
            N when is_integer(N) ->
               case exceeds(N, maps:get(max_body, State)) of
                  true -> {error, body_too_large};
                  false -> makeReqResult(MethodBin, Path, SchemeBin, Host, Port, Args, CompatHeaders, N, State)
               end;
            undefined ->
               makeReqResult(MethodBin, Path, SchemeBin, Host, Port, Args, CompatHeaders, undefined, State)
         end
   end.

validMethod(<<>>) -> false;
validMethod(Bin) -> validMethodChars(Bin).

validMethodChars(<<>>) -> true;
validMethodChars(<<C, Rest/binary>>) when
   (C >= $A andalso C =< $Z) orelse
   (C >= $a andalso C =< $z) orelse
   (C >= $0 andalso C =< $9) orelse
   C =:= $! orelse C =:= $# orelse C =:= $$ orelse C =:= $% orelse
   C =:= $& orelse C =:= $' orelse C =:= $* orelse C =:= $+ orelse
   C =:= $- orelse C =:= $. orelse C =:= $^ orelse C =:= $_ orelse
   C =:= $` orelse C =:= $| orelse C =:= $~ ->
   validMethodChars(Rest);
validMethodChars(_) -> false.

makeReqResult(MethodBin, Path, SchemeBin, Host, Port, Args, Regular, ContentLength, State) ->
   Req = #wsReq{
      method = methodValue(MethodBin),
      path = Path,
      version = {2, 0},
      scheme = SchemeBin,
      host = Host,
      port = Port,
      socket = maps:get(socket, State),
      args = Args,
      headers = internalHeaders(Regular)
   },
   {ok, Req, ContentLength}.

splitPathQuery(<<"*">>) -> {<<"*">>, []};
splitPathQuery(<<>>) -> {<<>>, []};
splitPathQuery(PathQuery) ->
   %% 无 query 是绝大多数请求：binary:match/2 直接返回，不创建
   %% binary:split/2 的 1~2 元临时列表。
   case binary:match(PathQuery, <<"?">>) of
      nomatch ->
         {PathQuery, []};
      {Pos, 1} ->
         <<Path:Pos/binary, "?", Query/binary>> = PathQuery,
         Args = try uri_string:dissect_query(Query) catch _:_ -> [] end,
         {Path, Args}
   end.

validateScheme(_Scheme, _Conn, <<"CONNECT">>) ->
   ok;
validateScheme(<<"http">>, http, _Method) ->
   ok;
validateScheme(<<"https">>, https, _Method) ->
   ok;
validateScheme(Scheme, _Conn, _Method) when Scheme =:= <<"http">>; Scheme =:= <<"https">> ->
   {error, scheme_mismatch};
validateScheme(undefined, _Conn, _Method) ->
   {error, missing_scheme};
validateScheme(_Scheme, _Conn, _Method) ->
   {error, invalid_scheme}.

validateAuthority(Authority, Hosts, Scheme) ->
   case hostsConsistent(Hosts) of
      false ->
         {error, conflicting_host};
      true ->
         HostHeader = case Hosts of [] -> undefined; [H | _] -> H end,
         case {Authority, HostHeader} of
            {undefined, undefined} ->
               {error, missing_authority};
            {undefined, HostValue} ->
               parseAuthority(HostValue, Scheme);
            {AuthValue, undefined} ->
               parseAuthority(AuthValue, Scheme);
            {AuthValue, HostValue} ->
               case wsUtil:headerNameEq(AuthValue, HostValue) of
                  false -> {error, authority_host_mismatch};
                  true -> parseAuthority(AuthValue, Scheme)
               end
         end
   end.

hostsConsistent([]) -> true;
hostsConsistent([First | Rest]) ->
   lists:all(fun(V) -> wsUtil:headerNameEq(V, First) end, Rest).

parseAuthority(undefined, Scheme) ->
   {ok, undefined, defaultPort(Scheme)};
parseAuthority(<<"[", Rest/binary>>, Scheme) ->
   case binary:match(Rest, <<"]">>) of
      nomatch -> {error, invalid_authority};
      {Pos, 1} ->
         <<Host:Pos/binary, "]", Tail/binary>> = Rest,
         case {Host, Tail} of
            {<<>>, _} -> {error, invalid_authority};
            {_, <<>>} -> {ok, Host, defaultPort(Scheme)};
            {_, <<":", P/binary>>} ->
               case parsePort(P) of
                  {ok, Port} -> {ok, Host, Port};
                  error -> {error, invalid_authority_port}
               end;
            _ -> {error, invalid_authority}
         end
   end;
parseAuthority(Authority, Scheme) when is_binary(Authority), Authority =/= <<>> ->
   case binary:match(Authority, <<":">>) of
      nomatch ->
         {ok, Authority, defaultPort(Scheme)};
      {Pos, 1} when Pos > 0 ->
         <<Host:Pos/binary, ":", P/binary>> = Authority,
         case binary:match(P, <<":">>) of
            nomatch ->
               case parsePort(P) of
                  {ok, Port} -> {ok, Host, Port};
                  error -> {error, invalid_authority_port}
               end;
            _ ->
               {error, invalid_authority}
         end;
      _ ->
         {error, invalid_authority}
   end;
parseAuthority(_, _) ->
   {error, invalid_authority}.

parsePort(P) ->
   try
      N = binary_to_integer(P),
      case N >= 1 andalso N =< 65535 of true -> {ok, N}; false -> error end
   catch _:_ -> error end.

defaultPort(<<"https">>) -> 443;
defaultPort(<<"http">>) -> 80;
defaultPort(_) -> undefined.

parseContentLengthValue(Value) when is_binary(Value), Value =/= <<>>, byte_size(Value) =< 20 ->
   case allDecimalDigits(Value) of
      true ->
         try binary_to_integer(Value) catch _:_ -> invalid end;
      false ->
         invalid
   end;
parseContentLengthValue(_) ->
   invalid.

allDecimalDigits(<<>>) ->
   true;
allDecimalDigits(<<C, Rest/binary>>) when C >= $0, C =< $9 ->
   allDecimalDigits(Rest);
allDecimalDigits(_) ->
   false.

validateTrailerHeaders(Headers) ->
   case lists:any(fun({Name, Value}) ->
      forbiddenTrailer(Name) orelse
      case Name of
         <<":", _/binary>> -> true;
         _ -> not validRegularHeader(Name, Value)
      end
   end, Headers) of
      true -> {error, invalid_trailer};
      false -> ok
   end.

%% RFC 9110 不允许这些字段出现在 trailer 里。放进来会改写已经校验过的请求。
forbiddenTrailer(<<"host">>) -> true;
forbiddenTrailer(<<"content-length">>) -> true;
forbiddenTrailer(<<"content-encoding">>) -> true;
forbiddenTrailer(<<"content-type">>) -> true;
forbiddenTrailer(<<"content-range">>) -> true;
forbiddenTrailer(<<"authorization">>) -> true;
forbiddenTrailer(<<"proxy-authorization">>) -> true;
forbiddenTrailer(<<"cookie">>) -> true;
forbiddenTrailer(<<"set-cookie">>) -> true;
forbiddenTrailer(<<"te">>) -> true;
forbiddenTrailer(<<"trailer">>) -> true;
forbiddenTrailer(<<"max-forwards">>) -> true;
forbiddenTrailer(_) -> false.

internalHeaders(Headers) ->
   [{internalHeaderName(Name), Value} || {Name, Value} <- Headers].

%% 与 erlang:decode_packet(httph_bin, ...) 的常用标准Header键保持一致，
%% 这样同一个WsMod无需区分HTTP/1.1与HTTP/2。
internalHeaderName(<<"cache-control">>) -> 'Cache-Control';
internalHeaderName(<<"date">>) -> 'Date';
internalHeaderName(<<"pragma">>) -> 'Pragma';
internalHeaderName(<<"via">>) -> 'Via';
internalHeaderName(<<"accept">>) -> 'Accept';
internalHeaderName(<<"accept-charset">>) -> 'Accept-Charset';
internalHeaderName(<<"accept-encoding">>) -> 'Accept-Encoding';
internalHeaderName(<<"accept-language">>) -> 'Accept-Language';
internalHeaderName(<<"authorization">>) -> 'Authorization';
internalHeaderName(<<"from">>) -> 'From';
internalHeaderName(<<"host">>) -> 'Host';
internalHeaderName(<<"if-modified-since">>) -> 'If-Modified-Since';
internalHeaderName(<<"if-match">>) -> 'If-Match';
internalHeaderName(<<"if-none-match">>) -> 'If-None-Match';
internalHeaderName(<<"if-range">>) -> 'If-Range';
internalHeaderName(<<"if-unmodified-since">>) -> 'If-Unmodified-Since';
internalHeaderName(<<"max-forwards">>) -> 'Max-Forwards';
internalHeaderName(<<"proxy-authorization">>) -> 'Proxy-Authorization';
internalHeaderName(<<"range">>) -> 'Range';
internalHeaderName(<<"referer">>) -> 'Referer';
internalHeaderName(<<"user-agent">>) -> 'User-Agent';
internalHeaderName(<<"age">>) -> 'Age';
internalHeaderName(<<"location">>) -> 'Location';
internalHeaderName(<<"proxy-authenticate">>) -> 'Proxy-Authenticate';
internalHeaderName(<<"retry-after">>) -> 'Retry-After';
internalHeaderName(<<"server">>) -> 'Server';
internalHeaderName(<<"vary">>) -> 'Vary';
internalHeaderName(<<"warning">>) -> 'Warning';
internalHeaderName(<<"www-authenticate">>) -> 'Www-Authenticate';
internalHeaderName(<<"allow">>) -> 'Allow';
internalHeaderName(<<"content-base">>) -> 'Content-Base';
internalHeaderName(<<"content-encoding">>) -> 'Content-Encoding';
internalHeaderName(<<"content-language">>) -> 'Content-Language';
internalHeaderName(<<"content-length">>) -> 'Content-Length';
internalHeaderName(<<"content-location">>) -> 'Content-Location';
internalHeaderName(<<"content-md5">>) -> 'Content-Md5';
internalHeaderName(<<"content-range">>) -> 'Content-Range';
internalHeaderName(<<"content-type">>) -> 'Content-Type';
internalHeaderName(<<"etag">>) -> 'Etag';
internalHeaderName(<<"expires">>) -> 'Expires';
internalHeaderName(<<"last-modified">>) -> 'Last-Modified';
internalHeaderName(<<"accept-ranges">>) -> 'Accept-Ranges';
internalHeaderName(<<"set-cookie">>) -> 'Set-Cookie';
internalHeaderName(<<"cookie">>) -> 'Cookie';
internalHeaderName(<<"origin">>) -> 'Origin';
internalHeaderName(<<"te">>) -> 'TE';
internalHeaderName(Name) -> Name.

headerListSize(Headers) ->
   {Size, _Count} = headerListStats(Headers),
   Size.

headerListStats(Headers) ->
   headerListStats(Headers, 0, 0).

headerListStats([], Size, Count) ->
   {Size, Count};
headerListStats([{N, V} | Rest], Size, Count) ->
   headerListStats(
      Rest,
      Size + byte_size(toBinary(N)) + byte_size(toBinary(V)) + 32,
      Count + 1
   ).

methodValue(<<"GET">>) -> 'GET';
methodValue(<<"POST">>) -> 'POST';
methodValue(<<"PUT">>) -> 'PUT';
methodValue(<<"PATCH">>) -> 'PATCH';
methodValue(<<"DELETE">>) -> 'DELETE';
methodValue(<<"HEAD">>) -> 'HEAD';
methodValue(<<"OPTIONS">>) -> 'OPTIONS';
methodValue(<<"CONNECT">>) -> 'CONNECT';
methodValue(<<"TRACE">>) -> 'TRACE';
methodValue(Bin) -> Bin.

toBinary(V) when is_binary(V) -> V;
toBinary(V) when is_integer(V) -> integer_to_binary(V);
toBinary(V) when is_atom(V) -> atom_to_binary(V, utf8);
toBinary(V) when is_list(V) -> iolist_to_binary(V).

exceeds(_Size, infinity) -> false;
exceeds(Size, Max) -> Size > Max.

streamError(StreamId, Code, State) ->
   _ = wsNet:send(maps:get(socket, State), wsHttp2Frame:rstStreamFrame(StreamId, Code)),
   dropStream(StreamId, State).

dropStream(StreamId, State) ->
   Streams = maps:get(streams, State),
   case maps:get(StreamId, Streams, undefined) of
      undefined ->
         ok;
      Stream ->
         _ = cancelRequestTimer(Stream),
         closeStreamFile(Stream),
         failStreamPendingAck(Stream),
         killStreamWorker(Stream)
   end,
   Pending = maps:get(send_pending_streams, State, #{}),
   State#{
      streams => maps:remove(StreamId, Streams),
      send_pending_streams => maps:remove(StreamId, Pending)
   }.

markSendPending(StreamId, State) ->
   Pending = maps:get(send_pending_streams, State, #{}),
   case maps:is_key(StreamId, Pending) of
      true -> State;
      false -> State#{send_pending_streams => Pending#{StreamId => true}}
   end.

clearSendPending(StreamId, State) ->
   Pending = maps:get(send_pending_streams, State, #{}),
   case maps:is_key(StreamId, Pending) of
      true -> State#{send_pending_streams => maps:remove(StreamId, Pending)};
      false -> State
   end.

%% @doc Stop any outstanding handler workers when the connection goes away.
terminate(State) ->
   _ = cancelSettingsTimer(State),
   maps:foreach(fun(_StreamId, Stream) ->
      _ = cancelRequestTimer(Stream),
      closeStreamFile(Stream),
      %% 连接在流控阻塞期间断开时，外部 chunk producer 仍可能在等 ACK。
      %% 必须先回失败再杀 worker，否则调用方会永久等待。
      failStreamPendingAck(Stream),
      killStreamWorker(Stream)
   end, maps:get(streams, State, #{})),
   ok.

killStreamWorker(#{handler_pid := Pid, handler_ref := Ref}) ->
   erlang:demonitor(Ref, [flush]),
   exit(Pid, kill),
   ok;
killStreamWorker(_Stream) ->
   ok.

closeStreamFile(Stream) ->
   case maps:get(pending_file, Stream, undefined) of
      {Fd, _Offset, _Left} -> catch file:close(Fd);
      _ -> ok
   end,
   ok.

cancelSettingsTimer(#{settings_ack_timer := Timer} = State) when Timer =/= undefined ->
   _ = erlang:cancel_timer(Timer),
   State#{settings_ack_timer => undefined, settings_ack_token => undefined};
cancelSettingsTimer(State) ->
   State.

touchStreamTimer(StreamId, State) ->
   Streams = maps:get(streams, State),
   case maps:get(StreamId, Streams, undefined) of
      undefined ->
         State;
      Stream0 ->
         Stream1 = armRequestTimer(StreamId, cancelRequestTimer(Stream0), State),
         State#{streams => Streams#{StreamId := Stream1}}
   end.

fileRemaining(Stream) ->
   case maps:get(pending_file, Stream, undefined) of
      {_Fd, _Offset, Left} when is_integer(Left) -> Left;
      _ -> 0
   end.

prepareSendBuffer(StreamId, State0) ->
   Streams = maps:get(streams, State0),
   Stream = maps:get(StreamId, Streams),
   case maps:get(pending_send, Stream, <<>>) of
      <<>> ->
         case maps:get(pending_file, Stream, undefined) of
            {Fd, Offset, Left} when Left > 0 ->
               fillFileBuffer(StreamId, Stream, Fd, Offset, Left, State0);
            _ ->
               {ok, State0}
         end;
      _ ->
         {ok, State0}
   end.

fillFileBuffer(StreamId, Stream, Fd, Offset, Left, State0) ->
   ConnWin = maps:get(send_conn_window, State0),
   StreamWin = maps:get(send_window, Stream),
   %% 文件读取批量与单次 DATA frame 上限是两件事。peer 可以把
   %% SETTINGS_MAX_FRAME_SIZE 提到接近 16MB，但不应因此让每个 stream
   %% 一次 pread/持有十几 MB。按发送 batch 上限读取，随后再按 peer
   %% max_frame 切帧，兼顾 syscall 数、内存峰值和多 stream 公平性。
   ReadMax = ?SEND_BATCH_BYTES,
   N = erlang:max(0, lists:min([Left, ConnWin, StreamWin, ReadMax])),
   case N of
      0 ->
         {ok, State0};
      _ ->
         case file:pread(Fd, Offset, N) of
            {ok, Data} when byte_size(Data) > 0 ->
               Read = byte_size(Data),
               Stream1 = Stream#{pending_send => Data, pending_file => {Fd, Offset + Read, Left - Read}},
               Streams = maps:get(streams, State0),
               {ok, State0#{streams => Streams#{StreamId := Stream1}}};
            eof ->
               _ = file:close(Fd),
               fileReadError(StreamId, Stream, State0);
            {ok, <<>>} ->
               _ = file:close(Fd),
               fileReadError(StreamId, Stream, State0);
            {error, Reason} ->
               _ = file:close(Fd),
               ?wsErr("HTTP/2 file read error stream=~p reason=~p", [StreamId, Reason]),
               fileReadError(StreamId, Stream, State0)
         end
   end.

fileReadError(StreamId, Stream, State0) ->
   Streams = maps:get(streams, State0),
   Stream1 = Stream#{pending_file => undefined, pending_send => <<>>, pending_end_stream => false},
   {ok, streamError(StreamId, internal_error, State0#{streams => Streams#{StreamId := Stream1}})}.

maybeFinishStream(StreamId, State0) ->
   Stream = maps:get(StreamId, maps:get(streams, State0)),
   case {maps:get(pending_send, Stream, <<>>), fileRemaining(Stream), maps:get(pending_end_stream, Stream, false)} of
      {<<>>, Left, true} when Left > 0 ->
         {ok, State0};
      {<<>>, 0, true} ->
         completePendingAck(maps:get(pending_ack, Stream, undefined), ok),
         {ok, dropStream(StreamId, State0)};
      {<<>>, 0, false} ->
         {ok, clearSendPending(StreamId, State0)};
      _ ->
         {ok, State0}
   end.

allowFrame(Type, Limit, State) ->
   Now = erlang:monotonic_time(millisecond),
   Rates0 = maps:get(frame_rates, State, #{}),
   {Start, Count} = maps:get(Type, Rates0, {Now, 0}),
   {Start1, Count1} =
      case Now - Start >= ?FRAME_RATE_WINDOW_MS of
         true -> {Now, 1};
         false -> {Start, Count + 1}
      end,
   State1 = State#{frame_rates => Rates0#{Type => {Start1, Count1}}},
   case Count1 > Limit of
      true -> {error, State1};
      false -> {ok, State1}
   end.

noteRapidReset(StreamId, State) ->
   case maps:get(StreamId, maps:get(streams, State), undefined) of
      #{response_started := true} ->
         {ok, State};
      undefined ->
         {ok, State};
      _Stream ->
         Now = erlang:monotonic_time(millisecond),
         Start = maps:get(rapid_reset_ts, State, 0),
         Count = maps:get(rapid_resets, State, 0),
         {Start1, Count1} =
            case Now - Start >= ?RAPID_RESET_WINDOW_MS of
               true -> {Now, 1};
               false -> {Start, Count + 1}
            end,
         State1 = State#{rapid_reset_ts => Start1, rapid_resets => Count1},
         case Count1 > ?RAPID_RESET_LIMIT of
            true -> {error, State1};
            false -> {ok, State1}
         end
   end.

connError(Code, Reason, State) ->
   Last = maps:get(last_client_stream, State, 0),
   _ = wsNet:send(maps:get(socket, State), wsHttp2Frame:goawayFrame(Last, Code)),
   {stop, {http2, Reason}, State#{goaway => true}}.
