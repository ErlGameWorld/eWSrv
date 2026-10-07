-module(wsNet).
-export([
	send/2
	, close/1
	, setopts/2
	, sendfile/5
	, peername/1
]).

send(Socket, Data) when is_port(Socket) ->
	ntCom:asyncSend(Socket, Data);
send(Socket, Data) ->
	ssl:send(Socket, Data).

close(undefined) -> ok;
close(Socket) when is_port(Socket) ->
	_ = (try lingerClose(Socket) catch _:_ -> ok end),
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


%% 关闭前先把接收侧读空：接收缓冲里若还有未读的请求体，直接 close 会让内核发
%% RST 而不是 FIN，而 RST 会让对端丢掉「已收到但还没读」的响应。触发前提是
%% 「客户端推了 body，但服务端没读」——典型是 413 / 417 这类先响应、不读 body
%% 的路径。连接 socket 处于 {active, N}，要先切回 passive 才能 recv。
%% 探测式实现：先零超时探一次，没有未读数据就不付任何等待成本（正常关闭走的
%% 就是这条零成本分支）。
lingerClose(Socket) ->
	case inet:setopts(Socket, [{active, false}]) of
		ok ->
			case gen_tcp:recv(Socket, 0, 0) of
				{ok, _} ->
					lingerDrain(Socket, 0, erlang:monotonic_time(millisecond) + 1000),
					ok;
				_ -> ok
			end;
		_ -> ok
	end.

%% 有界读空：总字节数 + 总时间双上限，每次 recv 间隔 20ms。
%% 对应 nginx 的 lingering_time / lingering_timeout，避免被持续慢速发送的
%% 连接拖住进程（读空过程不占 CPU，只让该连接进程多活一会儿）。
%% 1000ms 与 Cowboy 的 linger_timeout 默认值对齐。
lingerDrain(Socket, N, Deadline) when N < 33554432 ->
	case erlang:monotonic_time(millisecond) < Deadline of
		true ->
			case gen_tcp:recv(Socket, 0, 20) of
				{ok, B} -> lingerDrain(Socket, N + byte_size(B), Deadline);
				{error, _} -> ok
			end;
		false -> ok
	end;
lingerDrain(_Socket, _N, _Deadline) ->
	ok.
