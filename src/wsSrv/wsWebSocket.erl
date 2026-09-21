-module(wsWebSocket).

-include_lib("eNet/include/eNet.hrl").
-include("wsCom.hrl").

-export([
   parseWebSocketFrames/3
   , processFrames/2
   , handleUpgrade/2
   , genAcceptKey/1
   , tryWsUpgrade/1
   , sendFrame/3
   , encodeFrame/2
   , encodeFrame/1
]).

%% ================================================================================================
%% WebSocket frame parser
%% ================================================================================================

parseWebSocketFrames(<<>>, _State, Acc) ->
   {ok, lists:reverse(Acc), <<>>};
parseWebSocketFrames(Data, State, Acc) ->
   case parseWebSocketFrame(Data, State) of
      {ok, Frame, Rest} ->
         parseWebSocketFrames(Rest, State, [Frame | Acc]);
      {incomplete, RemainingData} ->
         {ok, lists:reverse(Acc), RemainingData};
      {error, Reason} ->
         {close, Reason}
   end.

parseWebSocketFrame(Data, _State) when byte_size(Data) < 2 ->
   {incomplete, Data};
parseWebSocketFrame(<<Fin:1, Rsv:3, Opcode:4, Mask:1, PayloadLen:7, Rest/binary>> = Data, State) ->
   case validateFrameHeader(Fin, Rsv, Opcode, Mask, PayloadLen) of
      ok ->
         parsePayloadLength(PayloadLen, Rest, Data, Fin, Opcode, State);
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
   %% RFC6455: client -> server frames MUST be masked.
   {error, protocol_error};
validateFrameHeader(0, _Rsv, Opcode, _Mask, _PayloadLen) when Opcode >= 8 ->
   {error, protocol_error};
validateFrameHeader(_Fin, _Rsv, Opcode, _Mask, PayloadLen) when Opcode >= 8, PayloadLen > 125 ->
   {error, protocol_error};
validateFrameHeader(_Fin, _Rsv, _Opcode, _Mask, _PayloadLen) ->
   ok.

parsePayloadLength(PayloadLen, Rest, Data, Fin, Opcode, State) when PayloadLen < 126 ->
   parsePayload(PayloadLen, Rest, Data, Fin, Opcode, State);
parsePayloadLength(126, Rest, Data, Fin, Opcode, State) ->
   case Rest of
      <<PayloadLength:16, Rest2/binary>> ->
         %% Extended form MUST be minimally encoded.
         case PayloadLength >= 126 of
            true -> parsePayload(PayloadLength, Rest2, Data, Fin, Opcode, State);
            false -> {error, protocol_error}
         end;
      _ ->
         {incomplete, Data}
   end;
parsePayloadLength(127, Rest, Data, Fin, Opcode, State) ->
   case Rest of
      <<0:1, PayloadLength:63, Rest2/binary>> ->
         %% Extended form MUST be minimally encoded and the high bit MUST be zero.
         case PayloadLength > 16#FFFF of
            true -> parsePayload(PayloadLength, Rest2, Data, Fin, Opcode, State);
            false -> {error, protocol_error}
         end;
      <<_High:1, _/bitstring>> ->
         {error, protocol_error};
      _ ->
         {incomplete, Data}
   end.

parsePayload(PayloadLength, _Rest, _Data, _Fin, _Opcode,
   #wsState{maxWsFrameSize = MaxFrame}) when PayloadLength > MaxFrame ->
   {error, message_too_big};
parsePayload(PayloadLength, Rest, Data, Fin, Opcode, _State) ->
   case Rest of
      <<MaskingKey:4/binary, PayloadData:PayloadLength/binary, Tail/binary>> ->
         UnmaskedData = unmaskData(PayloadData, MaskingKey),
         {ok, {Fin, Opcode, UnmaskedData}, Tail};
      _ ->
         {incomplete, Data}
   end.

%% O(n) unmask. 旧实现每4字节做一次 <<Acc/binary,...>>，大帧会退化成O(n²)。
unmaskData(Data, <<M0:8, M1:8, M2:8, M3:8>>) ->
   unmaskData(Data, M0, M1, M2, M3, 0, []).

unmaskData(<<A:8, B:8, C:8, D:8, Rest/binary>>, M0, M1, M2, M3, Index, Acc) ->
   MaskA = maskByte(Index, M0, M1, M2, M3),
   MaskB = maskByte(Index + 1, M0, M1, M2, M3),
   MaskC = maskByte(Index + 2, M0, M1, M2, M3),
   MaskD = maskByte(Index + 3, M0, M1, M2, M3),
   Chunk = <<(A bxor MaskA):8, (B bxor MaskB):8, (C bxor MaskC):8, (D bxor MaskD):8>>,
   unmaskData(Rest, M0, M1, M2, M3, Index + 4, [Chunk | Acc]);
unmaskData(<<Byte:8, Rest/binary>>, M0, M1, M2, M3, Index, Acc) ->
   Chunk = <<(Byte bxor maskByte(Index, M0, M1, M2, M3)):8>>,
   unmaskData(Rest, M0, M1, M2, M3, Index + 1, [Chunk | Acc]);
unmaskData(<<>>, _M0, _M1, _M2, _M3, _Index, Acc) ->
   iolist_to_binary(lists:reverse(Acc)).

maskByte(Index, M0, _M1, _M2, _M3) when Index band 3 =:= 0 -> M0;
maskByte(Index, _M0, M1, _M2, _M3) when Index band 3 =:= 1 -> M1;
maskByte(Index, _M0, _M1, M2, _M3) when Index band 3 =:= 2 -> M2;
maskByte(_Index, _M0, _M1, _M2, M3) -> M3.

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

processDataFrame(Fin, ?WsOpCF, Payload, Rest,
   #wsState{fragmented = true, fragmentedOpcode = FragOpcode,
      fragmentedBuffer = FragAcc, fragmentedSize = Size0,
      maxWsMessageSize = MaxMessage} = State) ->
   Size = Size0 + byte_size(Payload),
   case Size > MaxMessage of
      true ->
         {close, message_too_big, State};
      false when Fin =:= 0 ->
         processFrames(Rest, State#wsState{
            fragmentedBuffer = [Payload | FragAcc],
            fragmentedSize = Size
         });
      false ->
         Message = iolist_to_binary(lists:reverse([Payload | FragAcc])),
         Cleared = clearFragment(State),
         case validateMessage(FragOpcode, Message) of
            ok ->
               case doHandleWs(FragOpcode, Message, Cleared#wsState.webState,
                  Cleared#wsState.wsMod, Cleared#wsState.socket) of
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

processDataFrame(Fin, Opcode, Payload, Rest,
   #wsState{maxWsMessageSize = MaxMessage} = State)
   when Opcode =:= ?WsOpText; Opcode =:= ?WsOpBinary ->
   Size = byte_size(Payload),
   case Size > MaxMessage of
      true ->
         {close, message_too_big, State};
      false when Fin =:= 0 ->
         processFrames(Rest, State#wsState{
            fragmented = true,
            fragmentedOpcode = Opcode,
            fragmentedBuffer = [Payload],
            fragmentedSize = Size
         });
      false ->
         case validateMessage(Opcode, Payload) of
            ok ->
               case doHandleWs(Opcode, Payload, State#wsState.webState,
                  State#wsState.wsMod, State#wsState.socket) of
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
   State#wsState{
      fragmented = false,
      fragmentedOpcode = undefined,
      fragmentedBuffer = [],
      fragmentedSize = 0
   }.

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

validCloseCode(Code) when Code >= 1000, Code =< 1014,
   Code =/= 1004, Code =/= 1005, Code =/= 1006 -> true;
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
               _ = sendFrame(Socket, ?WsOpBinary, RetBody),
               {ok, NWebState};
            {ok, ROpCode, RetBody, NWebState} ->
               _ = sendFrame(Socket, ROpCode, RetBody),
               {ok, NWebState};
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
               _ = sendFrame(Socket, ROpCode, RetBody),
               {ok, NWebState};
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

sendFrame(Socket, Opcode, Payload0) ->
   Payload = iolist_to_binary(Payload0),
   wsNet:send(Socket, encodeFrame(Opcode, Payload)).

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
   Connection = wsUtil:getHeader('Connection', Headers, undefined),
   Upgrade = wsUtil:getHeader('Upgrade', Headers, undefined),
   Version = wsUtil:getHeader(<<"Sec-Websocket-Version">>, Headers, undefined),
   Key = wsUtil:getHeader(<<"Sec-Websocket-Key">>, Headers, undefined),
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
   Lower = wsUtil:toLowerStr(iolist_to_binary(Connection)),
   Tokens = [string:trim(T) || T <- binary:split(Lower, <<",">>, [global])],
   lists:member(<<"upgrade">>, Tokens).

isWebsocketUpgrade(undefined) ->
   false;
isWebsocketUpgrade(Upgrade) ->
   wsUtil:toLowerStr(string:trim(iolist_to_binary(Upgrade))) =:= <<"websocket">>.

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
