-module(wsWebSocket).

-include_lib("eNet/include/eNet.hrl").
-include("wsCom.hrl").

-export([
   feed/2
   , parseWebSocketFrames/3
   , processFrames/2
   , handleUpgrade/2
   , genAcceptKey/1
   , tryWsUpgrade/1
   , sendFrame/3
   , encodeFrame/2
   , encodeFrame/1
]).

%% ================================================================================================
%% Frame parser — 增量状态机，分段到达时不反复整段拷贝
%% ================================================================================================

%% @doc 喂入一段 TCP 数据。完整帧立即解出；半帧头留在 wsParse={hdr,_}，
%% 半 payload 用列表累积在 {body,...}，收齐再 iolist_to_binary 一次。
-spec feed(binary(), #wsState{}) ->
   {ok, [{0|1, non_neg_integer(), binary()}], #wsState{}} |
   {close, term()} | {error, term()}.
feed(Data, State) ->
   feed(Data, State#wsState.wsParse, State, []).

feed(<<>>, {body, Fin, Opcode, Mask, Need, AccParts, Size}, State, Acc) when Size >= Need ->
   Payload = case AccParts of
      [] -> <<>>;
      [One] -> One;
      _ -> iolist_to_binary(lists:reverse(AccParts))
   end,
   Frame = {Fin, Opcode, unmaskData(Payload, Mask)},
   feed(<<>>, {hdr, <<>>}, State, [Frame | Acc]);
feed(<<>>, undefined, State, Acc) ->
   {ok, lists:reverse(Acc), State#wsState{wsParse = undefined, buffer = <<>>}};
feed(<<>>, {hdr, <<>>}, State, Acc) ->
   {ok, lists:reverse(Acc), State#wsState{wsParse = undefined, buffer = <<>>}};
feed(<<>>, Parse, State, Acc) ->
   {ok, lists:reverse(Acc), State#wsState{wsParse = Parse, buffer = <<>>}};
feed(Data, undefined, State, Acc) ->
   feed(Data, {hdr, <<>>}, State, Acc);
feed(Data, {hdr, Buf0}, State, Acc) ->
   Buf = case Buf0 of <<>> -> Data; _ -> <<Buf0/binary, Data/binary>> end,
   case tryHeader(Buf, State) of
      {ok, Fin, Opcode, Mask, Len, Rest} ->
         feed(Rest, {body, Fin, Opcode, Mask, Len, [], 0}, State, Acc);
      {incomplete, Leftover} ->
         {ok, lists:reverse(Acc), State#wsState{wsParse = {hdr, Leftover}, buffer = <<>>}};
      {error, Reason} ->
         {error, Reason}
   end;
feed(Data, {body, Fin, Opcode, Mask, Need, AccParts, Size}, State, Acc) when Size >= Need ->
   Payload = case AccParts of
      [] -> <<>>;
      [One] -> One;
      _ -> iolist_to_binary(lists:reverse(AccParts))
   end,
   Frame = {Fin, Opcode, unmaskData(Payload, Mask)},
   feed(Data, {hdr, <<>>}, State, [Frame | Acc]);
feed(Data, {body, Fin, Opcode, Mask, Need, AccParts, Size}, State, Acc) ->
   Take = erlang:min(byte_size(Data), Need - Size),
   <<Chunk:Take/binary, Rest/binary>> = Data,
   feed(Rest, {body, Fin, Opcode, Mask, Need, [Chunk | AccParts], Size + Take}, State, Acc).

%% 兼容单测：整段输入一次解析，返回剩余 binary。
parseWebSocketFrames(Data, State, Acc0) ->
   case feed(Data, State#wsState{wsParse = undefined, buffer = <<>>}) of
      {ok, Frames, NState} ->
         {ok, Acc0 ++ Frames, remainingBytes(NState)};
      {close, Reason} ->
         {close, Reason};
      {error, Reason} ->
         {close, Reason}
   end.

remainingBytes(#wsState{wsParse = undefined}) -> <<>>;
remainingBytes(#wsState{wsParse = {hdr, Bin}}) -> Bin;
remainingBytes(#wsState{wsParse = {body, _, _, _, _, Acc, _}}) ->
   iolist_to_binary(lists:reverse(Acc)).

tryHeader(Data, _State) when byte_size(Data) < 2 ->
   {incomplete, Data};
tryHeader(<<Fin:1, Rsv:3, Opcode:4, Mask:1, PayloadLen:7, Rest/binary>> = Data, State) ->
   case validateFrameHeader(Fin, Rsv, Opcode, Mask, PayloadLen) of
      ok ->
         tryPayloadLength(PayloadLen, Rest, Data, Fin, Opcode, State);
      {error, Reason} ->
         {error, Reason}
   end.

validateFrameHeader(_Fin, Rsv, _Opcode, _Mask, _PayloadLen) when Rsv =/= 0 ->
   {error, protocol_error};
validateFrameHeader(_Fin, _Rsv, Opcode, _Mask, _PayloadLen)
   when Opcode =/= ?WsOpCF, Opcode =/= ?WsOpText, Opcode =/= ?WsOpBinary,
        Opcode =/= ?WsOpClose, Opcode =/= ?WsOpPing, Opcode =/= ?WsOpPong ->
   {error, protocol_error};
validateFrameHeader(_Fin, _Rsv, _Opcode, 0, _PayloadLen) ->
   {error, protocol_error};
validateFrameHeader(0, _Rsv, Opcode, _Mask, _PayloadLen) when Opcode >= 8 ->
   {error, protocol_error};
validateFrameHeader(_Fin, _Rsv, Opcode, _Mask, PayloadLen) when Opcode >= 8, PayloadLen > 125 ->
   {error, protocol_error};
validateFrameHeader(_Fin, _Rsv, _Opcode, _Mask, _PayloadLen) ->
   ok.

tryPayloadLength(PayloadLen, Rest, Data, Fin, Opcode, State) when PayloadLen < 126 ->
   takeMaskAndLen(PayloadLen, Rest, Data, Fin, Opcode, State);
tryPayloadLength(126, Rest, Data, Fin, Opcode, State) ->
   case Rest of
      <<PayloadLength:16, Rest2/binary>> ->
         case PayloadLength >= 126 of
            true -> takeMaskAndLen(PayloadLength, Rest2, Data, Fin, Opcode, State);
            false -> {error, protocol_error}
         end;
      _ ->
         {incomplete, Data}
   end;
tryPayloadLength(127, Rest, Data, Fin, Opcode, State) ->
   case Rest of
      <<0:1, PayloadLength:63, Rest2/binary>> ->
         case PayloadLength > 16#FFFF of
            true -> takeMaskAndLen(PayloadLength, Rest2, Data, Fin, Opcode, State);
            false -> {error, protocol_error}
         end;
      <<_High:1, _/bitstring>> ->
         {error, protocol_error};
      _ ->
         {incomplete, Data}
   end.

takeMaskAndLen(PayloadLength, _Rest, _Data, _Fin, _Opcode,
   #wsState{maxWsFrameSize = MaxFrame}) when PayloadLength > MaxFrame ->
   {error, message_too_big};
takeMaskAndLen(PayloadLength, Rest, Data, Fin, Opcode, _State) ->
   case Rest of
      <<MaskingKey:4/binary, AfterMask/binary>> ->
         {ok, Fin, Opcode, MaskingKey, PayloadLength, AfterMask};
      _ ->
         {incomplete, Data}
   end.

%% 掩码 4 字节周期且从 index 0 对齐，整字异或；尾部 0~3 字节逐字节处理。
unmaskData(<<>>, _Mask) -> <<>>;
unmaskData(Data, <<M0:8, M1:8, M2:8, M3:8>>) ->
   M32 = (M0 bsl 24) bor (M1 bsl 16) bor (M2 bsl 8) bor M3,
   %% 不能在每个 32-bit word 上做 <<Acc/binary,...>>：大帧会退化成 O(n²)
   %% 拷贝。反向累计小 binary，收尾只拼接一次。
   unmaskWords(Data, M32, M0, M1, M2, M3, []).

unmaskWords(<<W:32, Rest/binary>>, M32, M0, M1, M2, M3, Acc) ->
   unmaskWords(Rest, M32, M0, M1, M2, M3, [<<(W bxor M32):32>> | Acc]);
unmaskWords(<<A:8, B:8, C:8>>, _M32, M0, M1, M2, _M3, Acc) ->
   iolist_to_binary(lists:reverse([
      <<(A bxor M0):8, (B bxor M1):8, (C bxor M2):8>> | Acc
   ]));
unmaskWords(<<A:8, B:8>>, _M32, M0, M1, _M2, _M3, Acc) ->
   iolist_to_binary(lists:reverse([<<(A bxor M0):8, (B bxor M1):8>> | Acc]));
unmaskWords(<<A:8>>, _M32, M0, _M1, _M2, _M3, Acc) ->
   iolist_to_binary(lists:reverse([<<(A bxor M0):8>> | Acc]));
unmaskWords(<<>>, _M32, _M0, _M1, _M2, _M3, Acc) ->
   iolist_to_binary(lists:reverse(Acc)).

%% ================================================================================================
%% Frame processing / fragmentation
%% ================================================================================================

processFrames([], State) ->
   {ok, State};
processFrames([{Fin, Opcode, Payload} | Rest], State) when Opcode >= 8 ->
   processControlFrame(Fin, Opcode, Payload, Rest, State);
processFrames([{Fin, Opcode, Payload} | Rest], State) ->
   processDataFrame(Fin, Opcode, Payload, Rest, State).

processControlFrame(1, ?WsOpPing, Payload, Rest, #wsState{socket = Socket} = State) ->
   %% Ping/Pong允许穿插在fragmented message中，绝不能清空fragment状态。
   case sendFrame(Socket, ?WsOpPong, Payload) of
      ok -> processFrames(Rest, State);
      {error, Reason} -> {close, Reason, State}
   end;
processControlFrame(1, ?WsOpPong, Payload, Rest, State) ->
   case notifyControl(?WsOpPong, Payload, State) of
      {ok, NState} -> processFrames(Rest, NState);
      Close -> Close
   end;
processControlFrame(1, ?WsOpClose, Payload, _Rest, #wsState{socket = Socket} = State) ->
   case validateClosePayload(Payload) of
      ok ->
         %% 收到Close后回显Close payload，完成closing handshake。
         _ = sendFrame(Socket, ?WsOpClose, Payload),
         {close, normal, State};
      {error, Reason} ->
         {close, Reason, State}
   end;
processControlFrame(_Fin, _Opcode, _Payload, _Rest, State) ->
   {close, protocol_error, State}.

processDataFrame(Fin, ?WsOpCF, Payload, Rest, #wsState{fragmented = true, fragmentedOpcode = FragOpcode, fragmentedBuffer = FragAcc, fragmentedSize = Size0, maxWsMessageSize = MaxMessage} = State) ->
   Size = Size0 + byte_size(Payload),
   case Size > MaxMessage of
      true ->
         {close, message_too_big, State};
      false when Fin =:= 0 ->
         processFrames(Rest, State#wsState{fragmentedBuffer = [Payload | FragAcc], fragmentedSize = Size});
      false ->
         Message = iolist_to_binary(lists:reverse([Payload | FragAcc])),
         Cleared = clearFragment(State),
         case validateMessage(FragOpcode, Message) of
            ok ->
               case doHandleWs(FragOpcode, Message, Cleared#wsState.webState, Cleared#wsState.wsMod, Cleared#wsState.socket) of
                  {ok, NewWebState} ->
                     processFrames(Rest, Cleared#wsState{webState = NewWebState});
                  {close, Reason, NewWebState} ->
                     {close, Reason, Cleared#wsState{webState = NewWebState}}
               end;
            {error, Reason} ->
               {close, Reason, Cleared}
         end
   end;
processDataFrame(_Fin, ?WsOpCF, _Payload, _Rest, State) ->
   {close, protocol_error, State};

processDataFrame(_Fin, Opcode, _Payload, _Rest, #wsState{fragmented = true} = State)
   when Opcode =:= ?WsOpText; Opcode =:= ?WsOpBinary ->
   %% 一个fragmented message完成前不能开始新的data message。
   {close, protocol_error, State};

processDataFrame(Fin, Opcode, Payload, Rest, #wsState{maxWsMessageSize = MaxMessage} = State)
   when Opcode =:= ?WsOpText; Opcode =:= ?WsOpBinary ->
   Size = byte_size(Payload),
   case Size > MaxMessage of
      true ->
         {close, message_too_big, State};
      false when Fin =:= 0 ->
         processFrames(Rest, State#wsState{fragmented = true, fragmentedOpcode = Opcode, fragmentedBuffer = [Payload], fragmentedSize = Size});
      false ->
         case validateMessage(Opcode, Payload) of
            ok ->
               case doHandleWs(Opcode, Payload, State#wsState.webState, State#wsState.wsMod, State#wsState.socket) of
                  {ok, NewWebState} ->
                     processFrames(Rest, State#wsState{webState = NewWebState});
                  {close, Reason, NewWebState} ->
                     {close, Reason, State#wsState{webState = NewWebState}}
               end;
            {error, Reason} ->
               {close, Reason, State}
         end
   end;
processDataFrame(_Fin, _Opcode, _Payload, _Rest, State) ->
   {close, protocol_error, State}.

clearFragment(State) ->
   State#wsState{fragmented = false, fragmentedOpcode = undefined, fragmentedBuffer = [], fragmentedSize = 0}.

validateMessage(?WsOpText, Payload) ->
   validateUtf8(Payload);
validateMessage(?WsOpBinary, _Payload) ->
   ok.

validateUtf8(Bin) ->
   case unicode:characters_to_binary(Bin, utf8, utf8) of
      Converted when is_binary(Converted) -> ok;
      _ -> {error, invalid_utf8}
   end.

validateClosePayload(<<>>) ->
   ok;
validateClosePayload(<<_OneByte>>) ->
   {error, protocol_error};
validateClosePayload(<<Code:16, Reason/binary>>) ->
   case validCloseCode(Code) of
      false -> {error, protocol_error};
      true -> validateUtf8(Reason)
   end.

validCloseCode(Code) when Code >= 1000, Code =< 1014, Code =/= 1004, Code =/= 1005, Code =/= 1006 -> true;
validCloseCode(Code) when Code >= 3000, Code =< 4999 -> true;
validCloseCode(_) -> false.

notifyControl(Opcode, Payload, #wsState{wsMod = WsMod, webState = WebState, socket = Socket} = State) ->
   case erlang:function_exported(WsMod, handleWs, 3) of
      false ->
         {ok, State};
      true ->
         case doHandleWs(Opcode, Payload, WebState, WsMod, Socket) of
            {ok, NewWebState} -> {ok, State#wsState{webState = NewWebState}};
            {close, Reason, NewWebState} -> {close, Reason, State#wsState{webState = NewWebState}}
         end
   end.

doHandleWs(FragOpcode, Payload, WebState, WsMod, Socket) ->
   case erlang:function_exported(WsMod, handleWs, 3) of
      false ->
         {ok, WebState};
      true ->
         try WsMod:handleWs(FragOpcode, Payload, WebState) of
            {ok, NWebState} ->
               {ok, NWebState};
            {ok, RetBody, NWebState} ->
               sendHandlerFrame(Socket, ?WsOpBinary, RetBody, NWebState);
            {ok, ROpCode, RetBody, NWebState} ->
               sendHandlerFrame(Socket, ROpCode, RetBody, NWebState);
            {close, NWebState} ->
               {close, normal, NWebState};
            {close, Reason, NWebState} ->
               {close, Reason, NWebState};
            {stop, Reason, NWebState} ->
               {close, Reason, NWebState};
            Unexpected ->
               ?wsErr("handleWs return error FragOpcode:~p WebState:~p Unexpected:~p~n",
                  [FragOpcode, WebState, Unexpected]),
               {ok, WebState}
         catch
            throw:{ROpCode, RetBody, NWebState} when is_integer(ROpCode) ->
               sendHandlerFrame(Socket, ROpCode, RetBody, NWebState);
            throw:{ok, NWebState} ->
               {ok, NWebState};
            throw:{close, NWebState} ->
               {close, normal, NWebState};
            throw:{close, Reason, NWebState} ->
               {close, Reason, NWebState};
            throw:{stop, Reason, NWebState} ->
               {close, Reason, NWebState};
            Class:Reason:Stacktrace ->
               ?wsErr("handleWs exception opcode:~p class:~p reason:~p stack:~p~n",
                  [FragOpcode, Class, Reason, Stacktrace]),
               {ok, WebState}
         end
   end.

sendHandlerFrame(Socket, Opcode, Payload, WebState) ->
   case sendFrame(Socket, Opcode, Payload) of
      ok -> {ok, WebState};
      {error, Reason} -> {close, {send_frame, Reason}, WebState}
   end.

sendFrame(Socket, Opcode, Payload0) ->
   Payload = iolist_to_binary(Payload0),
   case validateOutboundFrame(Opcode, Payload) of
      ok -> wsNet:send(Socket, encodeFrame(Opcode, Payload));
      {error, _} = Error -> Error
   end.

validateOutboundFrame(?WsOpText, Payload) ->
   validateUtf8(Payload);
validateOutboundFrame(?WsOpBinary, _Payload) ->
   ok;
validateOutboundFrame(?WsOpCF, _Payload) ->
   %% Low-level continuation replies remain supported; outbound fragmentation
   %% state is owned by callers of encodeFrame/2.
   ok;
validateOutboundFrame(?WsOpClose, Payload) when byte_size(Payload) =< 125 ->
   validateClosePayload(Payload);
validateOutboundFrame(?WsOpPing, Payload) when byte_size(Payload) =< 125 ->
   ok;
validateOutboundFrame(?WsOpPong, Payload) when byte_size(Payload) =< 125 ->
   ok;
validateOutboundFrame(Opcode, _Payload)
   when Opcode =:= ?WsOpClose; Opcode =:= ?WsOpPing; Opcode =:= ?WsOpPong ->
   {error, control_frame_too_large};
validateOutboundFrame(_Opcode, _Payload) ->
   {error, invalid_opcode}.

encodeFrame(Payload) ->
   encodeFrame(?WsOpBinary, Payload).

encodeFrame(Opcode, Payload0) ->
   Payload = iolist_to_binary(Payload0),
   PayloadLen = byte_size(Payload),
   if
      PayloadLen < 126 ->
         <<1:1, 0:3, Opcode:4, 0:1, PayloadLen:7, Payload/binary>>;
      PayloadLen =< 16#FFFF ->
         <<1:1, 0:3, Opcode:4, 0:1, 126:7, PayloadLen:16, Payload/binary>>;
      true ->
         <<1:1, 0:3, Opcode:4, 0:1, 127:7, PayloadLen:64, Payload/binary>>
   end.

%% ================================================================================================
%% Upgrade handshake
%% ================================================================================================

-spec handleUpgrade(WsMod :: module(), BaseHeaders :: list()) -> {wsWebSocket, list()}.
handleUpgrade(_WsMod, BaseHeaders) ->
   %% Subprotocol/extension必须从客户端offer中协商后才能返回。
   %% 当前公共API没有把offer传到这里，因此宁可不声明，也不能无条件声明服务端列表。
   {wsWebSocket, BaseHeaders}.

-spec genAcceptKey(binary()) -> binary().
genAcceptKey(Key) ->
   Combined = <<Key/binary, ?WS_GUID/binary>>,
   Hash = crypto:hash(sha, Combined),
   base64:encode(Hash).

-spec tryWsUpgrade(#wsReq{}) -> {ok, list()} | {error, binary()}.
tryWsUpgrade(WsReq) ->
   #wsReq{method = Method, version = HttpVersion, headers = Headers} = WsReq,
   %% HTTP field-name 大小写不敏感；Sec-WebSocket-* 不是 decode_packet 的
   %% 固定 atom 表成员，不能依赖客户端恰好使用某一种拼写。
   Connection = wsHeaderValue('Connection', Headers, undefined),
   Upgrade = wsHeaderValue('Upgrade', Headers, undefined),
   Version = wsHeaderValue(<<"Sec-WebSocket-Version">>, Headers, undefined),
   Key = wsHeaderValue(<<"Sec-WebSocket-Key">>, Headers, undefined),
   case validateConditions(Method, HttpVersion, Connection, Upgrade, Version, Key) of
      ok ->
         AcceptKey = genAcceptKey(Key),
         WsHeaders = [
            {<<"Upgrade">>, <<"websocket">>},
            {<<"Connection">>, <<"Upgrade">>},
            {<<"Sec-Websocket-Accept">>, AcceptKey}
         ],
         {ok, WsHeaders};
      Error ->
         Error
   end.

wsHeaderValue(Name, Headers, Default) ->
   case lists:keyfind(Name, 1, Headers) of
      {_, Value} ->
         Value;
      false ->
         wsHeaderValueCi(Name, Headers, Default)
   end.

wsHeaderValueCi(_Name, [], Default) ->
   Default;
wsHeaderValueCi(Name, [{Key, Value} | Rest], Default) ->
   case wsUtil:headerNameEq(Key, Name) of
      true -> Value;
      false -> wsHeaderValueCi(Name, Rest, Default)
   end;
wsHeaderValueCi(Name, [_ | Rest], Default) ->
   wsHeaderValueCi(Name, Rest, Default).

validateConditions(Method, HttpVersion, Connection, Upgrade, Version, Key) ->
   maybe
      ok ?= case Method of 'GET' -> ok; _ -> {error, <<"method_not_allowed">>} end,
      ok ?= case HttpVersion >= {1, 1} of true -> ok; false -> {error, <<"http_version_not_supported">>} end,
      ok ?= case isUpgradeConnection(Connection) of true -> ok; false -> {error, <<"invalid_connection">>} end,
      ok ?= case isWebsocketUpgrade(Upgrade) of true -> ok; false -> {error, <<"invalid_upgrade">>} end,
      ok ?= case isSupportedVersion(Version) of true -> ok; false -> {error, <<"unsupported_version">>} end,
      ok ?= case isValidKey(Key) of true -> ok; false -> {error, <<"invalid_key">>} end
   end.

isUpgradeConnection(undefined) ->
   false;
isUpgradeConnection(Connection) ->
   Tokens = binary:split(iolist_to_binary(Connection), <<",">>, [global]),
   lists:any(fun(T) -> wsUtil:headerNameEq(string:trim(T), <<"upgrade">>) end, Tokens).

isWebsocketUpgrade(undefined) ->
   false;
isWebsocketUpgrade(Upgrade) ->
   wsUtil:headerNameEq(string:trim(iolist_to_binary(Upgrade)), <<"websocket">>).

isSupportedVersion(undefined) ->
   false;
isSupportedVersion(Version) ->
   string:trim(iolist_to_binary(Version)) =:= ?WS_VERSION.

isValidKey(undefined) ->
   false;
isValidKey(Key0) ->
   Key = string:trim(iolist_to_binary(Key0)),
   try
      Decoded = base64:decode(Key),
      byte_size(Decoded) =:= 16
   catch
      _:_ -> false
   end.
