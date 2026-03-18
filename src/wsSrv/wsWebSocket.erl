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

%% WebSocket帧解析
parseWebSocketFrames(<<>>, _State, Acc) ->
   {ok, lists:reverse(Acc), <<>>};
parseWebSocketFrames(Data, State, Acc) ->
   case parseWebSocketFrame(Data) of
      {ok, Frame, Rest} ->
         parseWebSocketFrames(Rest, State, [Frame | Acc]);
      {incomplete, RemainingData} ->
         {ok, lists:reverse(Acc), RemainingData}
   end.

parseWebSocketFrame(<<Fin:1, _Rsv:3, Opcode:4, Mask:1, PayloadLen:7, Rest/binary>> = Data) ->
   case PayloadLen of
      PayloadLen when PayloadLen < 126 ->
         PayloadLength = PayloadLen,
         case parsePayload(Mask, PayloadLength, Rest) of
            {ok, Frame, Rest3} -> {ok, {Fin, Opcode, Frame}, Rest3};
            {incomplete, _} -> {incomplete, <<Fin:1, _Rsv:3, Opcode:4, Mask:1, PayloadLen:7, Rest/binary>>};
            {error, Reason} -> {error, Reason}
         end;
      126 ->
         case Rest of
            <<PayloadLength:16, Rest2/binary>> ->
               case parsePayload(Mask, PayloadLength, Rest2) of
                  {ok, Frame, Rest3} -> {ok, {Fin, Opcode, Frame}, Rest3};
                  {incomplete, _} -> {incomplete, Data};
                  {error, Reason} -> {error, Reason}
               end;
            _ ->
               {incomplete, Data}
         end;
      127 ->
         case Rest of
            <<PayloadLength:64, Rest2/binary>> ->
               case parsePayload(Mask, PayloadLength, Rest2) of
                  {ok, Frame, Rest3} -> {ok, {Fin, Opcode, Frame}, Rest3};
                  {incomplete, _} -> {incomplete, Data};
                  {error, Reason} -> {error, Reason}
               end;
            _ ->
               {incomplete, Data}
         end
   end;
parseWebSocketFrame(Data) ->
   {incomplete, Data}.

parsePayload(Mask, PayloadLength, Data) ->
   case Mask of
      1 ->
         case Data of
            <<MaskingKey:4/binary, PayloadData:PayloadLength/binary, Rest3/binary>> ->
               UnmaskedData = unmaskData(PayloadData, MaskingKey),
               {ok, UnmaskedData, Rest3};
            _ ->
               {incomplete, Data}
         end;
      0 ->
         case Data of
            <<PayloadData:PayloadLength/binary, Rest3/binary>> ->
               {ok, PayloadData, Rest3};
            _ ->
               {incomplete, Data}
         end
   end.

unmaskData(Data, MaskingKey) ->
   <<M0:8, M1:8, M2:8, M3:8>> = MaskingKey,
   unmaskData(Data, M0, M1, M2, M3, 0, byte_size(Data), <<>>).

unmaskData(<<>>, _, _, _, _, _, _, Acc) ->
   Acc;
unmaskData(Data, M0, M1, M2, M3, Index, Remaining, Acc) when Remaining >= 4 ->
   <<A:8, B:8, C:8, D:8, Rest/binary>> = Data,
   MaskA = case Index rem 4 of 0 -> M0; 1 -> M1; 2 -> M2; 3 -> M3 end,
   MaskB = case (Index + 1) rem 4 of 0 -> M0; 1 -> M1; 2 -> M2; 3 -> M3 end,
   MaskC = case (Index + 2) rem 4 of 0 -> M0; 1 -> M1; 2 -> M2; 3 -> M3 end,
   MaskD = case (Index + 3) rem 4 of 0 -> M0; 1 -> M1; 2 -> M2; 3 -> M3 end,
   Unmasked = <<(A bxor MaskA):8, (B bxor MaskB):8, (C bxor MaskC):8, (D bxor MaskD):8>>,
   unmaskData(Rest, M0, M1, M2, M3, Index + 4, Remaining - 4, <<Acc/binary, Unmasked/binary>>);
unmaskData(Data, M0, M1, M2, M3, Index, Remaining, Acc) ->
   <<Byte:8, Rest/binary>> = Data,
   MaskByte = case Index rem 4 of 0 -> M0; 1 -> M1; 2 -> M2; 3 -> M3 end,
   UnmaskedByte = Byte bxor MaskByte,
   unmaskData(Rest, M0, M1, M2, M3, Index + 1, Remaining - 1, <<Acc/binary, UnmaskedByte:8>>).

%% 处理WebSocket帧
processFrames([], State) -> {ok, State};
processFrames([{Fin, Opcode, Payload} | Rest], #wsState{socket = Socket, wsMod = WsMod, webState = WebState, fragmented = Fragmented, fragmentedOpcode = FragOpcode, fragmentedBuffer = FragBuffer} = State) ->
   case Opcode of
      ?WsOpCF ->
         if
            Fragmented ->
               NewBuffer = <<FragBuffer/binary, Payload/binary>>,
               if
                  Fin =:= 1 ->
                     case doHandleWs(FragOpcode, NewBuffer, WebState, WsMod, Socket) of
                        {ok, NewWebState} ->
                           processFrames(Rest, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState});
                        {close, Reason, NewWebState} ->
                           {close, Reason, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState}}
                     end;
                  true ->
                     processFrames(Rest, State#wsState{fragmentedBuffer = NewBuffer})
               end;
            true ->
               ?wsErr("Received continuation frame without prior fragmented frame~n"),
               processFrames(Rest, State)
         end;
      ?WsOpText ->
         if
            Fin =:= 1 ->
               case doHandleWs(Opcode, Payload, WebState, WsMod, Socket) of
                  {ok, NewWebState} ->
                     processFrames(Rest, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState});
                  {close, Reason, NewWebState} ->
                     {close, Reason, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState}}
               end;
            true ->
               processFrames(Rest, State#wsState{fragmented = true, fragmentedOpcode = ?WsOpText, fragmentedBuffer = Payload})
         end;
      ?WsOpBinary ->
         if
            Fin =:= 1 ->
               case doHandleWs(Opcode, Payload, WebState, WsMod, Socket) of
                  {ok, NewWebState} ->
                     processFrames(Rest, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState});
                  {close, Reason, NewWebState} ->
                     {close, Reason, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState}}
               end;
            true ->
               processFrames(Rest, State#wsState{fragmented = true, fragmentedOpcode = ?WsOpBinary, fragmentedBuffer = Payload})
         end;
      ?WsOpClose ->
         case doHandleWs(Opcode, Payload, WebState, WsMod, Socket) of
            {ok, NewWebState} ->
               processFrames(Rest, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState});
            {close, Reason, NewWebState} ->
               {close, Reason, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState}}
         end;
      ?WsOpPing ->
         case doHandleWs(Opcode, Payload, WebState, WsMod, Socket) of
            {ok, NewWebState} ->
               processFrames(Rest, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState});
            {close, Reason, NewWebState} ->
               {close, Reason, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState}}
         end;
      ?WsOpPong ->
         case doHandleWs(Opcode, Payload, WebState, WsMod, Socket) of
            {ok, NewWebState} ->
               processFrames(Rest, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState});
            {close, Reason, NewWebState} ->
               {close, Reason, State#wsState{fragmented = false, fragmentedBuffer = <<>>, webState = NewWebState}}
         end;
      _ ->
         ?wsErr("Unknown WebSocket opcode: ~p~n", [Opcode]),
         processFrames(Rest, State)
   end.

doHandleWs(FragOpcode, Payload, WebState, WsMod, Socket) ->
   try WsMod:handleWs(FragOpcode, Payload, WebState) of
      {ok, NWebState} ->
         {ok, NWebState};
      {ok, RetBody, NWebState} ->
         sendFrame(Socket, ?WsOpBinary, RetBody),
         {ok, NWebState};
      {ok, ROpCode, RetBody, NWebState} ->
         sendFrame(Socket, ROpCode, RetBody),
         {ok, NWebState};
      {close, NWebState} ->
         {close, normal, NWebState};
      {close, Reason, NWebState} ->
         {close, Reason, NWebState};
      {stop, Reason, NWebState} ->
         {close, Reason, NWebState};
      %% Unexpected
      Unexpected ->
         ?wsErr("handleWs return error FragOpcode:~p WebState:~p Unexpected:~p Payload:~p ~n", [FragOpcode, WebState, Unexpected, Payload]),
         {ok, WebState}
   catch
      throw:{ROpCode, RetBody, NWebState} when is_integer(ROpCode) ->
         sendFrame(Socket, ROpCode, RetBody),
         {ok, NWebState};
      throw:{ok, NWebState} ->
         {ok, NWebState};
      throw:{close, NWebState} ->
         {close, normal, NWebState};
      throw:{close, Reason, NWebState} ->
         {close, Reason, NWebState};
      throw:{stop, Reason, NWebState} ->
         {close, Reason, NWebState};
      throw:Exc:Stacktrace ->
         ?wsErr("handleWs catch throw FragOpcode:~p WebState:~p Payload:~p throw:~p S:~p~n", [FragOpcode, WebState, Payload, Exc, Stacktrace]),
         {ok, WebState};
      error:Error:Stacktrace ->
         ?wsErr("handleWs catch error FragOpcode:~p WebState:~p Payload:~p Error:~p S:~p~n", [FragOpcode, WebState, Payload, Error, Stacktrace]),
         {ok, WebState};
      exit:Exit:Stacktrace ->
         ?wsErr("handleWs catch exit FragOpcode:~p WebState:~p Payload:~p Exit:~p S:~p~n", [FragOpcode, WebState, Payload, Exit, Stacktrace]),
         {ok, WebState}
   end.

sendFrame(Socket, Opcode, Payload) ->
   FrameBin = encodeFrame(Opcode, Payload),
   wsNet:send(Socket, FrameBin).

encodeFrame(Payload) ->
   encodeFrame(?WsOpBinary, Payload).
encodeFrame(Opcode, Payload) ->
   PayloadLen = byte_size(Payload),
   if
      PayloadLen < 126 ->
         <<1:1, 0:3, Opcode:4, 0:1, PayloadLen:7, Payload/binary>>;
      PayloadLen =< 16#FFFF ->
         <<1:1, 0:3, Opcode:4, 0:1, 126:7, PayloadLen:16, Payload/binary>>;
      true ->
         <<1:1, 0:3, Opcode:4, 0:1, 127:7, PayloadLen:64, Payload/binary>>
   end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc 处理WebSocket升级请求
-spec handleUpgrade(WsMod :: module(), BaseHeaders :: list()) -> {wsWebSocket, list()}.
handleUpgrade(WsMod, BaseHeaders) ->
   %% 添加WebSocket协议支持（如果模块支持）
   ProtocolHeaders = case erlang:function_exported(WsMod, supportedProtocols, 0) of
      true ->
         Protocols = WsMod:supportedProtocols(),
         case Protocols of
            [] -> [];
            _ ->
               <<_:8, ProtocolsStr/binary>> = <<<<",", OneP/binary>> || OneP <- Protocols>>,
               [{<<"Sec-Websocket-Protocol">>, ProtocolsStr}]
         end;
      _ ->
         []
   end,

   %% 添加WebSocket扩展支持（如果模块支持）
   ExtensionHeaders = case erlang:function_exported(WsMod, supportedExtensions, 0) of
      true ->
         Extensions = WsMod:supportedExtensions(),
         case Extensions of
            [] -> [];
            _ ->
               <<_:8, ExtensionsStr/binary>> = <<<<",", OneE/binary>> || OneE <- Extensions>>,
               [{<<"Sec-Websocket-Extensions">>, ExtensionsStr}]
         end;
      _ -> []
   end,
   %% 构建升级响应头
   ResponseHeaders = ProtocolHeaders ++ ExtensionHeaders ++ BaseHeaders,
   %% 返回升级响应
   {wsWebSocket, ResponseHeaders}.

%% @doc 生成WebSocket Accept Key
-spec genAcceptKey(binary()) -> binary().
genAcceptKey(Key) ->
   Combined = <<Key/binary, ?WS_GUID/binary>>,
   Hash = crypto:hash(sha, Combined),
   base64:encode(Hash).

%% @doc 检查是否为WebSocket升级请求
-spec tryWsUpgrade(#wsReq{}) -> {ok, list()} | {error, binary()}.
tryWsUpgrade(WsReq) ->
   #wsReq{method = Method, headers = Headers} = WsReq,
   Connection = wsUtil:getHeader('Connection', Headers, undefined),
   Upgrade = wsUtil:getHeader('Upgrade', Headers, undefined),
   Version = wsUtil:getHeader(<<"Sec-Websocket-Version">>, Headers, undefined),
   Key = wsUtil:getHeader(<<"Sec-Websocket-Key">>, Headers, undefined),
   case validateConditions(Method, Connection, Upgrade, Version, Key) of
      ok ->
         AcceptKey = genAcceptKey(Key),
         WsHeaders = [{<<"Upgrade">>, <<"websocket">>},
            {<<"Connection">>, <<"Upgrade">>},
            {<<"Sec-Websocket-Accept">>, AcceptKey}],
         {ok, WsHeaders};
      Error -> Error
   end.

%% 内部验证函数
validateConditions(Method, Connection, Upgrade, Version, Key) ->
   maybe
      ok  ?= case Method of 'GET' -> ok;_ -> {error, <<"method_not_allowed">>} end,
      ok  ?= case is_upgrade_connection(Connection) of true -> ok; false -> {error, <<"invalid_connection">>} end,
      ok  ?=  case is_websocket_upgrade(Upgrade) of true -> ok; false -> {error, <<"invalid_upgrade">>} end,
      ok  ?=  case is_supported_version(Version) of true -> ok; false -> {error, <<"unsupported_version">>} end,
      ok  ?=  case is_valid_key(Key) of true -> ok; false -> {error, <<"invalid_key">>} end
   end.

%% 检查Connection头是否包含"upgrade"
is_upgrade_connection(undefined) -> false;
is_upgrade_connection(Connection) ->
   binary:match(wsUtil:toLowerStr(Connection), <<"upgrade">>) /= nomatch.

%% 检查Upgrade头是否为"websocket"
is_websocket_upgrade(undefined) -> false;
is_websocket_upgrade(Upgrade) -> wsUtil:toLowerStr(Upgrade) =:= <<"websocket">>.

%% 检查WebSocket版本是否支持
is_supported_version(undefined) -> false;
is_supported_version(Version) -> Version =:= ?WS_VERSION.

%% 检查WebSocket Key是否有效 Key必须是16字节的base64编码
is_valid_key(undefined) -> false;
is_valid_key(Key) ->
   try
      Decoded = base64:decode(Key),
      byte_size(Decoded) =:= 16
   catch
      _:_ -> false
   end.