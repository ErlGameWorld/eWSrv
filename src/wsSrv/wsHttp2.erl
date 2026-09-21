-module(wsHttp2).

-include("wsCom.hrl").

-export([
   new/6, start/1, handleData/2,
   handleResponse/5, handleWorkerDown/3, handleRequestTimeout/3,
   handleStreamStart/7, handleStreamChunk/6, handleStreamClose/4,
   hasOpenStreams/1, idleClose/1, terminate/1
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

%% HTTP/2 server connection state. Socket ownership remains in wsHttp; this
%% module is a protocol state machine and performs writes through wsNet.
-spec new(wsSocket(), module(), http | https, non_neg_integer() | infinity, pos_integer(), pos_integer()) -> map().
new(Socket, WsMod, Scheme, MaxBody, MaxHeader, RequestTimeout) ->
   #{
      socket => Socket,
      ws_mod => WsMod,
      scheme => Scheme,
      phase => preface,
      preface_buffer => <<>>,
      parser => wsHttp2Frame:new(),
      rx_hpack => wsHpack:new(),
      tx_hpack => wsHpack:new(),
      streams => #{},
      header_frames => none,
      last_client_stream => 0,
      need_client_settings => true,
      expect_settings_ack => false,
      peer_max_frame => ?DEFAULT_MAX_FRAME,
      peer_initial_window => ?DEFAULT_WINDOW,
      peer_max_concurrent => infinity,
      peer_max_header_list => infinity,
      send_conn_window => ?DEFAULT_WINDOW,
      recv_conn_window => ?DEFAULT_WINDOW,
      local_initial_window => ?DEFAULT_WINDOW,
      max_body => MaxBody,
      max_header => MaxHeader,
      request_timeout => RequestTimeout,
      max_concurrent_streams => ?DEFAULT_MAX_STREAMS,
      goaway => false
   }.

-spec start(map()) -> {ok, map()} | {error, term()}.
start(State) ->
   Settings = [
      {header_table_size, 4096},
      {max_concurrent_streams, maps:get(max_concurrent_streams, State)},
      {initial_window_size, maps:get(local_initial_window, State)},
      {max_frame_size, ?DEFAULT_MAX_FRAME},
      {max_header_list_size, maps:get(max_header, State)}
   ],
   case wsNet:send(maps:get(socket, State), wsHttp2Frame:settingsFrame(Settings)) of
      ok -> {ok, State#{expect_settings_ack => true}};
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
   applyFrames(Frames, State0#{parser => Parser}).

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
      {StreamId, _Kind, _EndStream, _Acc, _Size} when Type =:= continuation ->
         case validateFrame(continuation, Flags, StreamId, Payload) of
            ok -> applyContinuation(Flags, StreamId, Payload, Rest, State0);
            {error, Code, Reason} -> connError(Code, Reason, State0)
         end;
      {_PendingStream, _Kind, _EndStream, _Acc, _Size} ->
         connError(protocol_error, expected_continuation, State0)
   end.

requireInitialSettings({frame, settings, Flags, 0, _}, #{need_client_settings := true} = State)
   when Flags band ?ACK =:= 0 ->
   {ok, State#{need_client_settings => false}};
requireInitialSettings(_Frame, #{need_client_settings := true}) ->
   {error, first_frame_must_be_settings};
requireInitialSettings(_Frame, State) ->
   {ok, State}.

validateFrame(Type, Flags, StreamId, Payload) ->
   case legalFlags(Type) of
      undefined -> validateStreamId(Type, StreamId, Payload);
      Legal ->
         case Flags band (bnot Legal) of
            0 -> validateStreamId(Type, StreamId, Payload);
            _ -> {error, protocol_error, {illegal_flags, Type, Flags}}
         end
   end.

legalFlags(data) -> ?END_STREAM bor ?PADDED;
legalFlags(headers) -> ?END_STREAM bor ?END_HEADERS bor ?PADDED bor ?PRIORITY;
legalFlags(priority) -> 0;
legalFlags(rst_stream) -> 0;
legalFlags(settings) -> ?ACK;
legalFlags(push_promise) -> ?END_HEADERS bor ?PADDED;
legalFlags(ping) -> ?ACK;
legalFlags(goaway) -> 0;
legalFlags(window_update) -> 0;
legalFlags(continuation) -> ?END_HEADERS;
legalFlags({unknown, _}) -> undefined;
legalFlags(_) -> undefined.

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
   case Flags band ?ACK of
      ?ACK ->
         case {Payload, maps:get(expect_settings_ack, State, false)} of
            {<<>>, true} -> applyFrames(Rest, State#{expect_settings_ack => false});
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
   end;
dispatch(ping, Flags, 0, Payload, Rest, State) ->
   case Flags band ?ACK of
      ?ACK -> applyFrames(Rest, State);
      _ ->
         case wsNet:send(maps:get(socket, State), wsHttp2Frame:pongFrame(Payload)) of
            ok -> applyFrames(Rest, State);
            {error, Reason} -> {stop, {socket_error, Reason}, State}
         end
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
         applyFrames(Rest, dropStream(StreamId, State))
   end;
dispatch(priority, _Flags, StreamId, Payload, Rest, State) ->
   case wsHttp2Frame:priorityFields(Payload) of
      {ok, _Exclusive, StreamId, _Weight, _} ->
         State1 = streamError(StreamId, protocol_error, State),
         applyFrames(Rest, State1);
      {ok, _Exclusive, _Dep, _Weight, <<>>} ->
         applyFrames(Rest, State);
      _ ->
         %% Length errors are handled by validateFrame/4 before dispatch.
         applyFrames(Rest, State)
   end;
dispatch(push_promise, _Flags, _StreamId, _Payload, _Rest, State) ->
   %% Clients cannot send PUSH_PROMISE.
   connError(protocol_error, client_push_promise, State);
dispatch(goaway, _Flags, 0, Payload, _Rest, State) ->
   case wsHttp2Frame:goawayFields(Payload) of
      {ok, _Last, Code, _Debug} -> {stop, {peer_goaway, Code}, State#{goaway => true}};
      {error, Reason} -> connError(frame_size_error, Reason, State)
   end;
dispatch({unknown, _}, _Flags, _StreamId, _Payload, Rest, State) ->
   applyFrames(Rest, State);
dispatch(_Other, _Flags, _StreamId, _Payload, Rest, State) ->
   applyFrames(Rest, State).

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
                  N -> wsHpack:setMax(N, Tx0)
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
                     State2 = State1#{header_frames => {StreamId, Kind, EndStream, [Block], Size}},
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
   #{header_frames := {StreamId, Kind, EndStream, Acc, Size0}} = State0) ->
   Size = Size0 + byte_size(Payload),
   case Size > maps:get(max_header, State0) of
      true ->
         %% We cannot skip the rest of a HPACK field block and keep using the
         %% connection: the dynamic table might be modified by skipped bytes.
         connError(enhance_your_calm, header_block_too_large,
            State0#{header_frames => none});
      false ->
         EndHeaders = Flags band ?END_HEADERS =/= 0,
         case EndHeaders of
            false ->
               State1 = State0#{header_frames => {StreamId, Kind, EndStream, [Payload | Acc], Size}},
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
         case headerListSize(Headers) > maps:get(max_header, State1) orelse length(Headers) > 100 of
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
                     %% HPACK state was advanced above; payload semantics are discarded.
                     applyFrames(Rest, State1)
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
         Stream = case EndStream of
            true -> Stream0;
            false -> armRequestTimer(StreamId, Stream0, State0)
         end,
         State1 = State0#{
            streams => (maps:get(streams, State0))#{StreamId => Stream},
            last_client_stream => StreamId
         },
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
                     Req = Req0#wsReq{headers = Req0#wsReq.headers ++ internalHeaders(Headers)},
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
               State1 = streamError(StreamId, flow_control_error, State0),
               applyFrames(Rest, State1);
            {true, true} ->
               case stripDataPayload(Flags, Payload) of
                  {error, Reason} ->
                     connError(protocol_error, Reason, State0);
                  {ok, BodyPart} ->
                     Size = maps:get(body_size, Stream0) + byte_size(BodyPart),
                     case exceeds(Size, maps:get(max_body, State0)) of
                        true ->
                           State1 = streamError(StreamId, enhance_your_calm, State0),
                           applyFrames(Rest, State1);
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
                                             case dispatchRequest(StreamId, State2) of
                                                {ok, State3} -> applyFrames(Rest, State3);
                                                Stop -> Stop
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
   case wsNet:send(maps:get(socket, State0),
      wsHttp2Frame:windowUpdateFrame(0, FlowBytes)) of
      ok ->
         {ok, State0#{
            recv_conn_window => maps:get(recv_conn_window, State0) + FlowBytes
         }};
      {error, Reason} ->
         {error, Reason, State0}
   end.

replenishReceiveWindows(_StreamId, 0, State) ->
   {ok, State};
replenishReceiveWindows(StreamId, FlowBytes, State0) ->
   Socket = maps:get(socket, State0),
   Frames = [
      wsHttp2Frame:windowUpdateFrame(0, FlowBytes),
      wsHttp2Frame:windowUpdateFrame(StreamId, FlowBytes)
   ],
   case wsNet:send(Socket, Frames) of
      ok ->
         Streams = maps:get(streams, State0),
         Stream = maps:get(StreamId, Streams),
         {ok, State0#{
            recv_conn_window => maps:get(recv_conn_window, State0) + FlowBytes,
            streams => Streams#{StreamId := Stream#{recv_window => maps:get(recv_window, Stream) + FlowBytes}}
         }};
      {error, Reason} ->
         {error, Reason, State0}
   end.

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
         StreamA = cancelRequestTimer(Stream0),
         Req0 = maps:get(req, StreamA),
         Body = case maps:get(body_acc, StreamA) of
            [] -> <<>>;
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
   TimerRef = erlang:send_after(
      maps:get(request_timeout, State), self(),
      {h2_request_timeout, StreamId, Token}),
   Stream#{request_timer => TimerRef, request_token => Token}.

cancelRequestTimer(#{request_timer := TimerRef} = Stream) ->
   _ = erlang:cancel_timer(TimerRef),
   maps:remove(request_token, maps:remove(request_timer, Stream));
cancelRequestTimer(Stream) ->
   Stream.

handleRequestTimeout(StreamId, Token, State) ->
   case maps:get(StreamId, maps:get(streams, State), undefined) of
      #{request_token := Token, remote_closed := false} ->
         ?wsWarn("HTTP/2 request timeout stream=~p", [StreamId]),
         {ok, streamError(StreamId, cancel, State)};
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
   Response = callHandler(WsMod, Req#wsReq.method, Req#wsReq.path, Req),
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
         Headers1 = normalizeResponseHeaders(Headers0, []),
         Headers = lists:keydelete(<<"content-length">>, 1, Headers1),
         H2Headers = [{<<":status">>, <<"200">>} | Headers],
         Tx0 = maps:get(tx_hpack, State),
         {Block, Tx} = wsHpack:encode(H2Headers, Tx0),
         HeadOnly = Method =:= 'HEAD',
         HFrames = wsHttp2Frame:headersFrames(
            Block, StreamId, maps:get(peer_max_frame, State), HeadOnly),
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
               State1 = State#{
                  tx_hpack => Tx,
                  streams => (maps:get(streams, State))#{StreamId := Stream1}
               },
               case Initial of
                  <<>> ->
                     WorkerPid ! {h2_chunk_ack, Token, ok},
                     {ok, State1};
                  _ ->
                     queueStreamChunk(StreamId, WorkerPid, Token, Initial, false, State1)
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
   Stream1 = Stream#{
      pending_send => Data,
      pending_end_stream => false,
      pending_ack => {WorkerPid, Token, From}
   },
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
   case findWorkerStream(MonitorRef, maps:to_list(maps:get(streams, State0))) of
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
         sendHandlerResponse(StreamId,
            {response, 500, [], <<"Internal server error">>}, Req, State1)
   end.

findWorkerStream(_Ref, []) ->
   none;
findWorkerStream(Ref, [{StreamId, #{handler_ref := Ref} = Stream} | _]) ->
   {StreamId, Stream};
findWorkerStream(Ref, [_ | Rest]) ->
   findWorkerStream(Ref, Rest).

callHandler(WsMod, Method, Path, Req) ->
   try WsMod:handle(Method, Path, Req) of
      {ok, Headers, {file, Filename}} -> {file, 200, Headers, Filename, []};
      {ok, Headers, {file, Filename, Range}} -> {file, 200, Headers, Filename, Range};
      {ok, Headers, Body} -> {response, 200, Headers, Body};
      {ok, Body} -> {response, 200, [], Body};
      {HttpCode, Headers, {file, Filename}} when is_integer(HttpCode) ->
         {file, HttpCode, Headers, Filename, []};
      {HttpCode, Headers, {file, Filename, Range}} when is_integer(HttpCode) ->
         {file, HttpCode, Headers, Filename, Range};
      {HttpCode, Headers, Body} when is_integer(HttpCode) ->
         {response, HttpCode, Headers, Body};
      {HttpCode, Body} when is_integer(HttpCode) ->
         {response, HttpCode, [], Body};
      {chunk, Headers} ->
         {chunk, Headers, <<>>};
      {chunk, Headers, Initial} ->
         {chunk, Headers, Initial};
      {wsUpgrade, _Headers} ->
         {response, 501, [], <<"WebSocket over HTTP/2 not enabled">>};
      Unexpected ->
         ?wsErr("HTTP/2 handler unexpected return req=~p ret=~p", [Req, Unexpected]),
         {response, 500, [], <<"Internal server error">>}
   catch
      Class:Reason:Stacktrace ->
         ?wsErr("HTTP/2 handler exception ~p:~p ~p", [Class, Reason, Stacktrace]),
         {response, 500, [], <<"Internal server error">>}
   end.

sendHandlerResponse(StreamId, {file, Code, Headers, Filename, Range}, Req, State) ->
   Method = Req#wsReq.method,
   case file:read_file(Filename) of
      {ok, Data0} ->
         case normalizeFileRange(Data0, Range) of
            {ok, Status, ExtraHeaders, Data} ->
               sendResponse(StreamId, statusOr(Code, Status), Headers ++ ExtraHeaders, Data, Method, State);
            invalid_range ->
               sendResponse(StreamId, 416, Headers, <<>>, Method, State)
         end;
      {error, _} ->
         sendResponse(StreamId, 500, [], <<"Internal server error">>, Method, State)
   end;
sendHandlerResponse(StreamId, {response, Code, Headers0, Body0}, Req, State) ->
   Method = Req#wsReq.method,
   {Body, Headers} = wsHttp:tryCompressResponse(
      Body0, Headers0, Req#wsReq.headers, Code, Method),
   sendResponse(StreamId, Code, Headers, Body, Method, State).

statusOr(Code, 200) -> Code;
statusOr(_Code, Status) -> Status.

normalizeFileRange(Data, []) -> {ok, 200, [], Data};
normalizeFileRange(Data, {0, 0}) -> {ok, 200, [], Data};
normalizeFileRange(Data, Range) ->
   Size = byte_size(Data),
   case wsUtil:normalizeRange(Range, Size) of
      undefined -> {ok, 200, [], Data};
      {Offset, Length} ->
         Part = binary:part(Data, Offset, Length),
         {ok, 206, [
            {<<"content-range">>, wsUtil:encodeRange({Offset, Length}, Size)}
         ], Part};
      invalid_range -> invalid_range
   end.

sendResponse(StreamId, Code, Headers0, Body0, Method, State0) ->
   Body = iolist_to_binary(Body0),
   SendBody = not (Method =:= 'HEAD' orelse Code =:= 204 orelse Code =:= 205 orelse Code =:= 304 orelse (Code >= 100 andalso Code < 200)),
   WireBody = case SendBody of true -> Body; false -> <<>> end,
   Headers1 = responseHeaders(Code, Headers0, byte_size(Body), Method),
   H2Headers = [{<<":status">>, integer_to_binary(Code)} | Headers1],
   case responseHeadersAllowed(headerListSize(H2Headers), State0) of
      false ->
         %% Respect the peer's advertised maximum field section size and keep
         %% handler-generated response headers bounded by our own safety limit.
         {ok, streamError(StreamId, internal_error, State0)};
      true ->
         Tx0 = maps:get(tx_hpack, State0),
         {Block, Tx} = wsHpack:encode(H2Headers, Tx0),
         EndOnHeaders = WireBody =:= <<>>,
         HFrames = wsHttp2Frame:headersFrames(
            Block, StreamId, maps:get(peer_max_frame, State0), EndOnHeaders),
         case wsNet:send(maps:get(socket, State0), HFrames) of
            {error, Reason} ->
               {stop, {socket_error, Reason}, State0};
            ok when EndOnHeaders ->
               {ok, dropStream(StreamId, State0#{tx_hpack => Tx})};
            ok ->
               Streams = maps:get(streams, State0),
               Stream = maps:get(StreamId, Streams),
               State1 = State0#{
                  tx_hpack => Tx,
                  streams => Streams#{StreamId := Stream#{
                     pending_send => WireBody,
                     pending_end_stream => true,
                     pending_ack => undefined,
                     response_started => true
                  }}
               },
               case flushPending(StreamId, State1) of
                  {ok, State2} -> {ok, State2};
                  {error, Code2, Reason2} -> connError(Code2, Reason2, State1)
               end
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
   Headers1 = normalizeResponseHeaders(Headers0, []),
   Headers2 = lists:keydelete(<<"content-length">>, 1, Headers1),
   case Code of
      C when C >= 100, C < 200 -> Headers2;
      204 -> Headers2;
      205 -> [{<<"content-length">>, <<"0">>} | Headers2];
      304 -> Headers2;
      _ when Method =:= 'HEAD' -> [{<<"content-length">>, integer_to_binary(BodySize)} | Headers2];
      _ -> [{<<"content-length">>, integer_to_binary(BodySize)} | Headers2]
   end.

normalizeResponseHeaders([], Acc) ->
   lists:reverse(Acc);
normalizeResponseHeaders([{Name0, Value0} | Rest], Acc) ->
   Name = wsUtil:toLowerStr(toBinary(Name0)),
   Value = toBinary(Value0),
   case {isHopByHop(Name), validMethod(Name), validHeaderValue(Value)} of
      {true, _, _} ->
         normalizeResponseHeaders(Rest, Acc);
      {false, true, true} ->
         normalizeResponseHeaders(Rest, [{Name, Value} | Acc]);
      _ ->
         %% Handler-generated malformed fields must never corrupt the H2 stream.
         ?wsWarn("ignore invalid HTTP/2 response header name=~p", [Name]),
         normalizeResponseHeaders(Rest, Acc)
   end.

flushAllPending(State0) ->
   Ids = maps:keys(maps:get(streams, State0)),
   lists:foldl(fun(Id, Acc) ->
      case Acc of
         {ok, State} -> flushPending(Id, State);
         Other -> Other
      end
   end, {ok, State0}, Ids).

flushPending(StreamId, State0) ->
   Streams = maps:get(streams, State0),
   case maps:get(StreamId, Streams, undefined) of
      undefined -> {ok, State0};
      Stream ->
         Pending = maps:get(pending_send, Stream, <<>>),
         case Pending of
            <<>> -> {ok, State0};
            _ -> flushPendingLoop(StreamId, Pending, State0)
         end
   end.

flushPendingLoop(StreamId, Pending, State0) ->
   Streams = maps:get(streams, State0),
   Stream = maps:get(StreamId, Streams),
   ConnWin = maps:get(send_conn_window, State0),
   StreamWin = maps:get(send_window, Stream),
   MaxFrame = maps:get(peer_max_frame, State0),
   Allowed = erlang:max(0, lists:min([byte_size(Pending), ConnWin, StreamWin, MaxFrame])),
   case Allowed of
      0 ->
         {ok, State0};
      N ->
         <<Chunk:N/binary, Rest/binary>> = Pending,
         EndStream = maps:get(pending_end_stream, Stream, true),
         Flags =
            case {Rest, EndStream} of
               {<<>>, true} -> ?END_STREAM;
               _ -> 0
            end,
         Frame = wsHttp2Frame:frame(data, StreamId, Chunk, Flags),
         case wsNet:send(maps:get(socket, State0), Frame) of
            {error, Reason} ->
               completePendingAck(maps:get(pending_ack, Stream, undefined),
                  {error, closed}),
               {error, internal_error, {socket_error, Reason}};
            ok ->
               Stream1 = Stream#{
                  send_window => StreamWin - N,
                  pending_send => Rest
               },
               State1 = State0#{
                  send_conn_window => ConnWin - N,
                  streams => Streams#{StreamId := Stream1}
               },
               case Rest of
                  <<>> when EndStream ->
                     completePendingAck(maps:get(pending_ack, Stream1, undefined), ok),
                     {ok, dropStream(StreamId, State1)};
                  <<>> ->
                     completePendingAck(maps:get(pending_ack, Stream1, undefined), ok),
                     Streams1 = maps:get(streams, State1),
                     Stream2 = maps:get(StreamId, Streams1),
                     {ok, State1#{streams => Streams1#{StreamId := Stream2#{
                        pending_ack => undefined,
                        pending_end_stream => false
                     }}}};
                  _ ->
                     flushPendingLoop(StreamId, Rest, State1)
               end
         end
   end.

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
                     buildRequest(Method, Pseudo, Regular, Seen, State)
               end
         end
   end.

parseHeaderList([], Pseudo, Regular, _Phase, Seen) ->
   {ok, Pseudo, lists:reverse(Regular), Seen};
parseHeaderList([{Name0, Value0} | Rest], Pseudo, Regular, Phase, Seen) ->
   Name = toBinary(Name0),
   Value = toBinary(Value0),
   case Name =:= wsUtil:toLowerStr(Name) of
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
                     case validRegularHeader(Name, Value) of
                        false -> {error, {bad_header, Name}};
                        true -> parseHeaderList(Rest, Pseudo, [{Name, Value} | Regular], regular, Seen)
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

validRegularHeader(Name, Value) ->
   case isHopByHop(Name) of
      true -> false;
      false when Name =:= <<"te">> ->
         wsUtil:toLowerStr(string:trim(Value)) =:= <<"trailers">>;
      false -> validHeaderValue(Value)
   end.

validHeaderValue(Value) ->
   binary:match(Value, <<"\r">>) =:= nomatch andalso
   binary:match(Value, <<"\n">>) =:= nomatch andalso
   binary:match(Value, <<0>>) =:= nomatch.

isHopByHop(<<"connection">>) -> true;
isHopByHop(<<"proxy-connection">>) -> true;
isHopByHop(<<"keep-alive">>) -> true;
isHopByHop(<<"transfer-encoding">>) -> true;
isHopByHop(<<"upgrade">>) -> true;
isHopByHop(_) -> false.

buildRequest(<<"CONNECT">>, Pseudo, Regular, _Seen, State) ->
   case {maps:get(<<":authority">>, Pseudo, undefined),
         maps:get(<<":scheme">>, Pseudo, undefined),
         maps:get(<<":path">>, Pseudo, undefined)} of
      {undefined, _, _} -> {error, missing_authority};
      {_Authority, undefined, undefined} ->
         makeRequest(<<"CONNECT">>, Pseudo, Regular, State);
      _ -> {error, bad_connect_pseudo_headers}
   end;
buildRequest(MethodBin, Pseudo, Regular, _Seen, State) ->
   case {maps:get(<<":scheme">>, Pseudo, undefined), maps:get(<<":path">>, Pseudo, undefined)} of
      {undefined, _} -> {error, missing_scheme};
      {_, undefined} -> {error, missing_path};
      {_Scheme, <<>>} -> {error, empty_path};
      {_Scheme, <<"*">>} when MethodBin =:= <<"OPTIONS">> ->
         makeRequest(MethodBin, Pseudo, Regular, State);
      {_Scheme, <<"*">>} ->
         {error, asterisk_path_requires_options};
      {_Scheme, <<"/", _/binary>>} ->
         makeRequest(MethodBin, Pseudo, Regular, State);
      _ ->
         {error, invalid_path}
   end.

makeRequest(MethodBin, Pseudo, Regular, State) ->
   PathQuery = maps:get(<<":path">>, Pseudo, <<>>),
   {Path, Args} = splitPathQuery(PathQuery),
   SchemeBin = maps:get(<<":scheme">>, Pseudo,
      case maps:get(scheme, State) of https -> <<"https">>; _ -> <<"http">> end),
   Authority = maps:get(<<":authority">>, Pseudo, undefined),
   HostHeader = headerValue(<<"host">>, Regular, undefined),
   case validateAuthority(Authority, HostHeader, SchemeBin) of
      {error, _} = Error ->
         Error;
      {ok, Host, Port} ->
         CompatHeaders = ensureHostHeader(Regular, Authority),
         ContentLength = parseContentLengthHeaders(CompatHeaders),
         case ContentLength of
            {error, _} = Error -> Error;
            N when is_integer(N) ->
               case exceeds(N, maps:get(max_body, State)) of
                  true -> {error, body_too_large};
                  false -> makeReqResult(MethodBin, Path, SchemeBin, Host, Port, Args, CompatHeaders, N, State)
               end;
            undefined ->
               makeReqResult(MethodBin, Path, SchemeBin, Host, Port, Args, CompatHeaders, undefined, State)
         end
   end.

ensureHostHeader(Regular, undefined) ->
   Regular;
ensureHostHeader(Regular, Authority) ->
   case lists:keyfind(<<"host">>, 1, Regular) of
      false -> [{<<"host">>, Authority} | Regular];
      _ -> Regular
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
   case binary:split(PathQuery, <<"?">>) of
      [Path] -> {Path, []};
      [Path, Query] ->
         Args = try uri_string:dissect_query(Query) catch _:_ -> [] end,
         {Path, Args}
   end.

validateAuthority(Authority, HostHeader, Scheme) ->
   case {Authority, HostHeader} of
      {undefined, undefined} ->
         {ok, undefined, defaultPort(Scheme)};
      {undefined, HostValue} ->
         parseAuthority(HostValue, Scheme);
      {AuthValue, undefined} ->
         parseAuthority(AuthValue, Scheme);
      {AuthValue, HostValue} ->
         case wsUtil:toLowerStr(AuthValue) =:= wsUtil:toLowerStr(HostValue) of
            false -> {error, authority_host_mismatch};
            true -> parseAuthority(AuthValue, Scheme)
         end
   end.

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
   case binary:split(Authority, <<":">>, [global]) of
      [Host] when Host =/= <<>> -> {ok, Host, defaultPort(Scheme)};
      [Host, P] when Host =/= <<>> ->
         case parsePort(P) of
            {ok, Port} -> {ok, Host, Port};
            error -> {error, invalid_authority_port}
         end;
      _ -> {error, invalid_authority}
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

parseContentLengthHeaders(Headers) ->
   Values = [V || {<<"content-length">>, V} <- Headers],
   case Values of
      [] -> undefined;
      [First | Rest] ->
         try
            N = binary_to_integer(First),
            case N >= 0 andalso lists:all(fun(V) -> V =:= First end, Rest) of
               true -> N;
               false -> {error, conflicting_content_length}
            end
         catch _:_ -> {error, invalid_content_length} end
   end.

validateTrailerHeaders(Headers) ->
   case lists:any(fun({Name, Value}) ->
      case Name of
         <<":", _/binary>> -> true;
         _ -> not validRegularHeader(Name, Value)
      end
   end, Headers) of
      true -> {error, invalid_trailer};
      false -> ok
   end.

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

headerValue(Name, Headers, Default) ->
   case lists:keyfind(Name, 1, Headers) of
      false -> Default;
      {_, Value} -> Value
   end.

headerListSize(Headers) ->
   lists:sum([byte_size(toBinary(N)) + byte_size(toBinary(V)) + 32 || {N, V} <- Headers]).

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
         failStreamPendingAck(Stream),
         case Stream of
            #{handler_pid := Pid, handler_ref := Ref} ->
               erlang:demonitor(Ref, [flush]),
               exit(Pid, kill);
            _ ->
               ok
         end
   end,
   State#{streams => maps:remove(StreamId, Streams)}.

%% @doc Stop any outstanding handler workers when the connection goes away.
terminate(State) ->
   maps:foreach(fun(_StreamId, Stream) ->
      _ = cancelRequestTimer(Stream),
      case Stream of
         #{handler_pid := Pid, handler_ref := Ref} ->
            erlang:demonitor(Ref, [flush]),
            exit(Pid, kill);
         _ ->
            ok
      end
   end, maps:get(streams, State, #{})),
   ok.

connError(Code, Reason, State) ->
   Last = maps:get(last_client_stream, State, 0),
   _ = wsNet:send(maps:get(socket, State), wsHttp2Frame:goawayFrame(Last, Code)),
   {stop, {http2, Reason}, State#{goaway => true}}.
