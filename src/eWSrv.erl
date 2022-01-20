-module(eWSrv).

-include("wsCom.hrl").

-export([
   start/0
   , stop/0
   , openSrv/2
   , openSrv/3
   , closeSrv/1
   , wSrvName/1
]).

start() ->
   application:ensure_all_started(eWSrv).

stop() ->
   application:stop(eWSrv).

wSrvName(Port) ->
   binary_to_atom(<<"$WSrv", (integer_to_binary(Port))/binary>>).

openSrv(Port, WsOpts) ->
   T1WsOpts = lists:keystore(conMod, 1, WsOpts, {conMod, wsHttp}),
   WsMod = ?wsGLV(wsMod, WsOpts, wsTPHer),
   MaxSize = ?wsGLV(maxSize, WsOpts, infinity),
   ChunkedSupp = ?wsGLV(chunkedSupp, WsOpts, false),
   T2WsOpts = lists:keystore(conArgs, 1, T1WsOpts, {conArgs, {WsMod, MaxSize, ChunkedSupp}}),
   TcpOpts = ?wsGLV(tcpOpts, T2WsOpts, []),
   NewTcpOpts = wsUtil:mergeOpts(?DefWsOpts, TcpOpts),
   LWsOpts = lists:keystore(tcpOpts, 1, T2WsOpts, {tcpOpts, NewTcpOpts}),

   WSrvName = wSrvName(Port),

   case ?wsGLV(sslOpts, WsOpts, false) of
      false ->
         {ok, _} = eNet:openTcp(WSrvName, Port, LWsOpts);
      _ ->
         {ok, _} = eNet:openSsl(WSrvName, Port, LWsOpts)
   end.

openSrv(WSrvName, Port, WsOpts) ->
   T1WsOpts = lists:keystore(conMod, 1, WsOpts, {conMod, wsHttp}),
   WsMod = ?wsGLV(wsMod, WsOpts, wsTPHer),
   MaxSize = ?wsGLV(maxSize, WsOpts, infinity),
   ChunkedSupp = ?wsGLV(chunkedSupp, WsOpts, false),
   T2WsOpts = lists:keystore(conArgs, 1, T1WsOpts, {conArgs, {WsMod, MaxSize, ChunkedSupp}}),
   TcpOpts = ?wsGLV(tcpOpts, T2WsOpts, []),
   NewTcpOpts = wsUtil:mergeOpts(?DefWsOpts, TcpOpts),
   LWsOpts = lists:keystore(tcpOpts, 1, T2WsOpts, {tcpOpts, NewTcpOpts}),

   case ?wsGLV(sslOpts, WsOpts, false) of
      false ->
         {ok, _} = eNet:openTcp(WSrvName, Port, LWsOpts);
      _ ->
         {ok, _} = eNet:openSsl(WSrvName, Port, LWsOpts)
   end.

closeSrv(WSrvNameOrPort) ->
   WSrvName = ?IIF(is_integer(WSrvNameOrPort),  wSrvName(WSrvNameOrPort), WSrvNameOrPort),
   eNet:close(WSrvName).