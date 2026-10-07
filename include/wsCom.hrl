-include("eWSrv.hrl").

-define(wsErr(Str), logger:error(Str)).
-define(wsErr(Format, Args), logger:error(Format, Args)).
-define(wsWarn(Format, Args), logger:warning(Format, Args)).
-define(wsInfo(Format, Args), logger:info(Format, Args)).
-define(wsGLV(Key, List, Default), wsUtil:gLV(Key, List, Default)).

-define(DefWsOpts, [
	binary
	, {packet, raw}
	, {active, false}
	, {reuseaddr, true}
	, {nodelay, true}
	, {delay_send, false}
	, {send_timeout, 15000}
	%% 发送超时即关连接。Ranch 的 ranch_tcp:prepare_socket_opts/2 默认就是 true；
	%% 为 false 时发送超时只返回 {error, timeout}，连接仍留着，上层若不主动关
	%% 就会积压半死连接（对端已停止读取）。
	, {send_timeout_close, true}
	, {keepalive, true}
	, {exit_on_close, true}
	, {backlog, 4096}
	%% 64 KB 减少大请求的 TCP 消息数，同时避免默认给每条小请求连接
	%% 配置 128 KB 的用户态 buffer 和 512 KB 的内核接收缓冲。
	%% 可通过 openSrv 的 tcpOpts 为上传专用监听器覆盖。
	, {buffer, 65536}
	, {recbuf, 262144}
]).

%% {active, N} 限制连接进程来不及处理时积压的 TCP 消息数。
%% 默认 N=128、buffer=64 KB 时，最坏可在单连接 mailbox 中排队约 8 MB。
%% 若 handler 经常阻塞，应按连接数和内存预算下调 N。
-define(ActionN, 128).

%% HTTP/WebSocket 安全默认值。均可通过 openSrv/2,3 的 WsOpts 覆盖。
-define(DefMaxBodySize, 8 * 1024 * 1024).
-define(DefMaxRequestLineSize, 8 * 1024).
-define(DefMaxHeaderSize, 64 * 1024).
-define(DefMaxWsFrameSize, 1 * 1024 * 1024).
-define(DefMaxWsMessageSize, 8 * 1024 * 1024).
-define(DefRequestTimeout, 30000).
-define(DefKeepAliveTimeout, 60000).
-define(DefHttp2MaxConcurrentStreams, 100).
-define(DefHttp2ReceiveWindow, 65535).

-define(CASE(Cond, Then, That), case Cond of true -> Then; _ -> That end).

-export_type([
	sendfile_opts/0
]).

-type sendfile_opts() :: [{chunk_size, non_neg_integer()}].

-type stage() :: reqLine | wsHeader | wsBody | wsDone | wsWs | wsWsClosing. %% 接收HTTP/WebSocket数据阶段
-record(wsState, {
	stage = reqLine :: stage()                                       %% 接收数据阶段
	, buffer = <<>> :: binary()                                      %% 缓存接收到的数据
	, wsParse = undefined :: undefined | {hdr, binary()} | {body, 0 | 1, non_neg_integer(), binary(), non_neg_integer(), [binary()], non_neg_integer()}
	%% WebSocket 增量解析：hdr 暂存不完整帧头；body 用列表累积分片，收齐再拼一次
	, wsReq :: undefined | #wsReq{}                                  %% 解析后的http
	, headerCnt = 0 :: non_neg_integer()                             %% header计数
	, headerBytes = 0 :: non_neg_integer()                           %% 已解析header总字节数
	, hostHeaderSeen = false :: boolean()                            %% 是否收到Host头
	, reqConnClose = false :: boolean()                              %% 请求Connection是否包含close
	, reqConnKeepAlive = false :: boolean()                          %% 请求Connection是否包含keep-alive
	, temHeader = [] :: wsHeaders()                                  %% 解析header临时数据
	, contentLength :: undefined | non_neg_integer() | chunked       %% 长度
	, bodyAcc = [] :: [binary()]                                     %% Body分段，避免反复拼binary
	, bodySize = 0 :: non_neg_integer()                              %% 已接收Body长度
	, chunkState = size :: size | crlf | trailers | {data, non_neg_integer()} %% chunked解析状态
	, temChunked = <<>> :: binary()                                  %% 兼容旧状态字段，不再用于累计Body
	, method :: wsMethod()                                           %% 请求的method
	, path :: binary()                                               %% 请求的URL
	, rn :: undefined | binary:cp()                                  %% binary:cp()
	, socket :: undefined | inet:socket() | ssl:sslsocket()          %% 连接的socket
	, isSsl = false :: boolean()                                     %% 是否是ssl
	, wsMod :: module()                                              %% 回调请求的模块
	, maxSize = ?DefMaxBodySize :: infinity | pos_integer()          %% 单次允许接收的最大长度
	, maxRequestLineSize = ?DefMaxRequestLineSize :: pos_integer()   %% 请求行上限
	, maxHeaderSize = ?DefMaxHeaderSize :: pos_integer()             %% 请求头总大小上限
	, maxWsFrameSize = ?DefMaxWsFrameSize :: pos_integer()           %% WebSocket单帧上限
	, maxWsMessageSize = ?DefMaxWsMessageSize :: pos_integer()       %% WebSocket单消息上限
	, chunkedSupp = false :: boolean()                               %% 是否允许客户端发送chunked
	, requestTimeout = ?DefRequestTimeout :: pos_integer()           %% 单个HTTP请求总超时
	, keepAliveTimeout = ?DefKeepAliveTimeout :: pos_integer()       %% 空闲Keep-Alive超时
	, requestStartedAt :: undefined | integer()                      %% 当前HTTP请求开始时间(monotonic ms)
	, http2Enabled = true :: boolean()                               %% 是否启用HTTP/2
	, http2MaxConcurrentStreams = ?DefHttp2MaxConcurrentStreams :: pos_integer()
	, http2ReceiveWindow = ?DefHttp2ReceiveWindow :: 65535..2147483647
	, protocol = detect :: detect | http1 | http2                    %% 当前连接线协议
	, h2State :: undefined | wsHttp2:state()                          %% HTTP/2连接状态

	, is_behavior = false :: boolean()                               %% 是否是行为连接
	, fragmented = false :: boolean()                                %% websocket
	, fragmentedOpcode :: integer()                                  %% websocket 操作码
	, fragmentedBuffer = [] :: [binary()]                            %% websocket 分片缓存（逆序）
	, fragmentedSize = 0 :: non_neg_integer()                        %% websocket 分片累计长度
	, fragmentedUtf8Tail = <<>> :: binary()                          %% 文本分片间尚未完成的 UTF-8 序列（最多3字节）
	, wsCloseDeadline :: undefined | integer()                      %% 主动关闭时等待对端Close的绝对截止时间
	, webState :: term()                                             %% websocket链接状态数据
}).

%% WebSocket握手常量
-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(WS_VERSION, <<"13">>).
