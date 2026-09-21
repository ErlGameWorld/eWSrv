-module(wsHttp2).

-include("wsCom.hrl").

-export([new/5, start/1, handleData/2]).

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
-spec new(wsSocket(), module(), http | https, non_neg_integer() | infinity, pos_integer()) -> map().
new(Socket, WsMod, Scheme, MaxBody, MaxHeader) ->
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
      peer_max_frame => ?DEFAULT_MAX_FRAME,
      peer_initial_window => ?DEFAULT_WINDOW,
      peer_max_concurrent => infinity,
      send_conn_window => ?DEFAULT_WINDOW,
      recv_conn_window => ?DEFAULT_WINDOW,
      local_initial_window => ?DEFAULT_WINDOW,
      max_body => MaxBody,
      max_header => MaxHeader,
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
      ok -> {ok, State};
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
            {error, Code, Reason} ->
               connError(Code, Reason, State0)
         end;
      {StreamId, _Kind, _EndStream, _Acc, _Size} when Type =:= continuation ->
         applyContinuation(Flags, StreamId, Payload, Rest, State0);
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
         case Payload of
            <<>> -> applyFrames(Rest, State);
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
   end;
dispatch(headers, Flags, StreamId, Payload, Rest, State) ->
   applyHeaders(Flags, StreamId, Payload, Rest, State);
dispatch(continuation, _Flags, _StreamId, _Payload, _Rest, State) ->
   connError(protocol_error, unexpected_continuation, State);
dispatch(data, Flags, StreamId, Payload, Rest, State) ->
   applyData(Flags, StreamId, Payload, Rest, State);
dispatch(rst_stream, _Flags, StreamId, _Payload, Rest, State) ->
   applyFrames(Rest, dropStream(StreamId, State));
dispatch(priority, _Flags, StreamId, Payload, Rest, State) ->
   case wsHttp2Frame:priorityFields(Payload) of
      {ok, _Exclusive, StreamId, _Weight, _} ->
         connError(protocol_error, priority_self_dependency, State);
      {ok, _Exclusive, _Dep, _Weight, <<>>} ->
         applyFrames(Rest, State);
      _ ->
         connError(frame_size_error, bad_priority, State)
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
                  peer_max_concurrent => proplists:get_value(max_concurrent_streams, Settings, maps:get(peer_max_concurrent, State0))
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
            {error, Reason} ->
               connError(protocol_error, Reason, State0);
            Kind ->
               Size = byte_size(Block),
               case Size > maps:get(max_header, State0) of
                  true ->
                     State1 = streamError(StreamId, enhance_your_calm, State0),
                     applyFrames(Rest, State1);
                  false when EndHeaders ->
                     finishHeaderBlock(StreamId, Kind, EndStream, Block, Rest, State0);
                  false ->
                     State1 = State0#{header_frames => {StreamId, Kind, EndStream, [Block], Size}},
                     applyFrames(Rest, State1)
               end
         end
   end.

classifyHeaders(StreamId, State) ->
   Streams = maps:get(streams, State),
   case maps:is_key(StreamId, Streams) of
      true -> trailer;
      false ->
         Last = maps:get(last_client_stream, State),
         case {StreamId band 1, StreamId > Last, maps:get(goaway, State, false)} of
            {1, true, false} ->
               case map_size(Streams) < maps:get(max_concurrent_streams, State) of
                  true -> initial;
                  false -> {error, too_many_streams}
               end;
            {0, _, _} -> {error, client_stream_must_be_odd};
            {1, false, _} -> {error, reused_or_out_of_order_stream};
            {_, _, true} -> {error, stream_after_goaway}
         end
   end.

applyContinuation(Flags, StreamId, Payload, Rest,
   #{header_frames := {StreamId, Kind, EndStream, Acc, Size0}} = State0) ->
   Size = Size0 + byte_size(Payload),
   case Size > maps:get(max_header, State0) of
      true ->
         State1 = streamError(StreamId, enhance_your_calm, State0#{header_frames => none}),
         applyFrames(Rest, State1);
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
                  initial -> finishInitialHeaders(StreamId, EndStream, Headers, Rest, State1);
                  trailer -> finishTrailers(StreamId, EndStream, Headers, Rest, State1)
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
         Stream = #{
            req => Req,
            body_acc => [],
            body_size => 0,
            content_length => ContentLength,
            recv_window => maps:get(local_initial_window, State0),
            send_window => maps:get(peer_initial_window, State0),
            pending_send => <<>>,
            response_started => false
         },
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
                     Req = Req0#wsReq{headers = Req0#wsReq.headers ++ Headers},
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
         case StreamId > maps:get(last_client_stream, State0) of
            true -> connError(protocol_error, data_on_idle_stream, State0);
            false ->
               State1 = streamError(StreamId, stream_closed, State0),
               applyFrames(Rest, State1)
         end;
      Stream0 ->
         FlowBytes = byte_size(Payload),
         ConnWin = maps:get(recv_conn_window, State0),
         StreamWin = maps:get(recv_window, Stream0),
         case {FlowBytes =< ConnWin, FlowBytes =< StreamWin} of
            {false, _} -> connError(flow_control_error, connection_receive_window_exceeded, State0);
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
                              {error, Reason, State2} -> {stop, {socket_error, Reason}, State2};
                              {ok, State2} ->
                                 case Flags band ?END_STREAM =/= 0 of
                                    false -> applyFrames(Rest, State2);
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
   Req0 = maps:get(req, Stream0),
   Body = case maps:get(body_acc, Stream0) of
      [] -> <<>>;
      Acc -> iolist_to_binary(lists:reverse(Acc))
   end,
   Req = Req0#wsReq{body = Body},
   Response = callHandler(maps:get(ws_mod, State0), Req#wsReq.method, Req#wsReq.path, Req),
   sendHandlerResponse(StreamId, Response, Req#wsReq.method, State0).

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
      {chunk, _Headers} ->
         {response, 501, [], <<"HTTP/2 streaming callback not enabled">>};
      {chunk, _Headers, _Initial} ->
         {response, 501, [], <<"HTTP/2 streaming callback not enabled">>};
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

sendHandlerResponse(StreamId, {file, Code, Headers, Filename, Range}, Method, State) ->
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
sendHandlerResponse(StreamId, {response, Code, Headers, Body}, Method, State) ->
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
   SendBody = not (Method =:= 'HEAD' orelse Code =:= 204 orelse Code =:= 304 orelse (Code >= 100 andalso Code < 200)),
   WireBody = case SendBody of true -> Body; false -> <<>> end,
   Headers1 = responseHeaders(Code, Headers0, byte_size(Body), Method),
   H2Headers = [{<<":status">>, integer_to_binary(Code)} | Headers1],
   Tx0 = maps:get(tx_hpack, State0),
   {Block, Tx} = wsHpack:encode(H2Headers, Tx0),
   EndOnHeaders = WireBody =:= <<>>,
   HFrames = wsHttp2Frame:headersFrames(Block, StreamId, maps:get(peer_max_frame, State0), EndOnHeaders),
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
               response_started => true
            }}
         },
         case flushPending(StreamId, State1) of
            {ok, State2} -> {ok, State2};
            {error, Code2, Reason2} -> connError(Code2, Reason2, State1)
         end
   end.

responseHeaders(Code, Headers0, BodySize, Method) ->
   Headers1 = normalizeResponseHeaders(Headers0, []),
   Headers2 = lists:keydelete(<<"content-length">>, 1, Headers1),
   case Code of
      C when C >= 100, C < 200 -> Headers2;
      204 -> Headers2;
      304 -> Headers2;
      _ when Method =:= 'HEAD' -> [{<<"content-length">>, integer_to_binary(BodySize)} | Headers2];
      _ -> [{<<"content-length">>, integer_to_binary(BodySize)} | Headers2]
   end.

normalizeResponseHeaders([], Acc) ->
   lists:reverse(Acc);
normalizeResponseHeaders([{Name0, Value0} | Rest], Acc) ->
   Name = wsUtil:toLowerStr(toBinary(Name0)),
   case isHopByHop(Name) of
      true -> normalizeResponseHeaders(Rest, Acc);
      false -> normalizeResponseHeaders(Rest, [{Name, toBinary(Value0)} | Acc])
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
      0 -> {ok, State0};
      N ->
         <<Chunk:N/binary, Rest/binary>> = Pending,
         Flags = case Rest of <<>> -> ?END_STREAM; _ -> 0 end,
         Frame = wsHttp2Frame:frame(data, StreamId, Chunk, Flags),
         case wsNet:send(maps:get(socket, State0), Frame) of
            {error, Reason} -> {error, internal_error, {socket_error, Reason}};
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
                  <<>> -> {ok, dropStream(StreamId, State1)};
                  _ -> flushPendingLoop(StreamId, Rest, State1)
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
            {undefined, _} -> {error, missing_method};
            {_, P} when P =/= undefined -> {error, extended_connect_not_enabled};
            _ ->
               buildRequest(MethodBin, Pseudo, Regular, Seen, State)
         end
   end.

parseHeaderList([], Pseudo, Regular, _Phase, Seen) ->
   {ok, Pseudo, lists:reverse(Regular), Seen};
parseHeaderList([{Name0, Value0} | Rest], Pseudo, Regular, Phase, Seen) ->
   Name = toBinary(Name0),
   Value = toBinary(Value0),
   case Name =:= wsUtil:toLowerStr(Name) of
      false -> {error, uppercase_header_name};
      true ->
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
      false when Name =:= <<"te">> -> wsUtil:toLowerStr(Value) =:= <<"trailers">>;
      false -> true
   end.

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
      _ -> makeRequest(MethodBin, Pseudo, Regular, State)
   end.

makeRequest(MethodBin, Pseudo, Regular, State) ->
   PathQuery = maps:get(<<":path">>, Pseudo, <<>>),
   {Path, Args} = splitPathQuery(PathQuery),
   SchemeBin = maps:get(<<":scheme">>, Pseudo,
      case maps:get(scheme, State) of https -> <<"https">>; _ -> <<"http">> end),
   Authority = case maps:get(<<":authority">>, Pseudo, undefined) of
      undefined -> headerValue(<<"host">>, Regular, undefined);
      A -> A
   end,
   {Host, Port} = parseAuthority(Authority, SchemeBin),
   ContentLength = parseContentLengthHeaders(Regular),
   case ContentLength of
      {error, _} = Error -> Error;
      _ ->
         Req = #wsReq{
            method = methodValue(MethodBin),
            path = Path,
            version = {2, 0},
            scheme = SchemeBin,
            host = Host,
            port = Port,
            socket = maps:get(socket, State),
            args = Args,
            headers = Regular
         },
         {ok, Req, ContentLength}
   end.

splitPathQuery(<<"*">>) -> {<<"*">>, []};
splitPathQuery(<<>>) -> {<<>>, []};
splitPathQuery(PathQuery) ->
   case binary:split(PathQuery, <<"?">>) of
      [Path] -> {Path, []};
      [Path, Query] ->
         Args = try uri_string:dissect_query(Query) catch _:_ -> [] end,
         {Path, Args}
   end.

parseAuthority(undefined, Scheme) ->
   {undefined, defaultPort(Scheme)};
parseAuthority(<<"[", Rest/binary>>, Scheme) ->
   case binary:match(Rest, <<"]">>) of
      nomatch -> {undefined, defaultPort(Scheme)};
      {Pos, 1} ->
         <<Host:Pos/binary, "]", Tail/binary>> = Rest,
         Port = case Tail of
            <<":", P/binary>> -> parsePort(P, defaultPort(Scheme));
            _ -> defaultPort(Scheme)
         end,
         {Host, Port}
   end;
parseAuthority(Authority, Scheme) ->
   case binary:split(Authority, <<":">>, [global]) of
      [Host] -> {Host, defaultPort(Scheme)};
      [Host, P] -> {Host, parsePort(P, defaultPort(Scheme))};
      _ -> {Authority, defaultPort(Scheme)}
   end.

parsePort(P, Default) ->
   try
      N = binary_to_integer(P),
      case N >= 1 andalso N =< 65535 of true -> N; false -> Default end
   catch _:_ -> Default end.

defaultPort(<<"https">>) -> 443;
defaultPort(_) -> 80.

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
   State#{streams => maps:remove(StreamId, maps:get(streams, State))}.

connError(Code, Reason, State) ->
   Last = maps:get(last_client_stream, State, 0),
   _ = wsNet:send(maps:get(socket, State), wsHttp2Frame:goawayFrame(Last, Code)),
   {stop, {http2, Reason}, State#{goaway => true}}.
