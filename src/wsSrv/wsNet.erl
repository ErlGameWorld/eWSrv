%%% @doc Wrapper for plain and SSL sockets.
%%% Based on `mochiweb_socket.erl'.

-module(wsNet).
-export([
   send/2
   , close/1
   , setopts/2
   , sendfile/5
   , peername/1
]).

send(Socket, Data) when is_port(Socket) ->
   ntCom:syncSend(Socket, Data);
send(Socket, Data) ->
   ssl:send(Socket, Data).

close(undefined) -> ok;
close(Socket) when is_port(Socket) ->
   gen_tcp:close(Socket);
close(Socket) ->
   ssl:close(Socket).

setopts(Socket, Opts) when is_port(Socket) ->
   inet:setopts(Socket, Opts);
setopts(Socket, Opts) ->
   ssl:setopts(Socket, Opts).

sendfile(Fd, Socket, Offset, Length, Opts) when is_port(Socket) ->
   file:sendfile(Fd, Socket, Offset, Length, Opts);
sendfile(Fd, Socket, Offset, Length, Opts) ->
   wsUtil:sendfile(Fd, Socket, Offset, Length, Opts).

peername(Socket) when is_port(Socket) ->
   inet:peername(Socket);
peername(Socket) ->
   ssl:peername(Socket).
