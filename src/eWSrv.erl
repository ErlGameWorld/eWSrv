-module(eWSrv).

-include("wsCom.hrl").

-export([
   start/0
   , stop/0
   , openSrv/2
   , openSrv/3
   , closeSrv/1
   , wSrvName/1
   , main/1
]).

-export([
   method/1
   , path/1
   , version/1
   , scheme/1
   , host/1
   , port/1
   , socket/1
   , args/1
   , mapargs/1
   , headers/1
   , body/1
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
   WsSupName = ?wsGLV(wsSupName, WsOpts, undefined),
   T2WsOpts = lists:keystore(conArgs, 1, T1WsOpts, {conArgs, {WsSupName, WsMod, MaxSize, ChunkedSupp}}),
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
   WsSupName = ?wsGLV(wsSupName, WsOpts, undefined),
   T2WsOpts = lists:keystore(conArgs, 1, T1WsOpts, {conArgs, {WsSupName, WsMod, MaxSize, ChunkedSupp}}),
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
   WSrvName = ?CASE(is_integer(WSrvNameOrPort), wSrvName(WSrvNameOrPort), WSrvNameOrPort),
   eNet:close(WSrvName).

%% ========== escript entry ==========
%% Usage: _build/default/bin/eWSrv --port 8888
main([PortStr]) ->
   Port = list_to_integer(PortStr),
   {ok, _} = start(),
   case openSrv(Port, []) of
      {ok, _} ->
         io:format("eWSrv listening on http://0.0.0.0:~p/~n", [Port]),
         io:format("Open http://127.0.0.1:~p/demo for the demo page.\n", [Port]),
         receive after infinity -> ok end;
      Error ->
         io:format("Failed to open server: ~p~n", [Error]),
         erlang:halt(1)
   end.


method(#wsReq{method = Method}) -> Method.
path(#wsReq{path = Path}) -> Path.
version(#wsReq{version = Version}) -> Version.
scheme(#wsReq{scheme = Scheme}) -> Scheme.
host(#wsReq{host = Host}) -> Host.
port(#wsReq{port = Port}) -> Port.
socket(#wsReq{socket = Socket}) -> Socket.
args(#wsReq{args = Args}) -> Args.
mapargs(#wsReq{args = Args}) -> maps:from_list(Args).
headers(#wsReq{headers = Headers}) -> Headers.
body(#wsReq{body = Body}) -> Body.