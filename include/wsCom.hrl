-include("eWSrv.hrl").

-define(wsErr(Str), error_logger:error_msg(Str)).
-define(wsErr(Format, Args), error_logger:error_msg(Format, Args)).
-define(wsWarn(Format, Args), error_logger:warning_msg(Format, Args)).
-define(wsInfo(Format, Args), error_logger:info_msg(Format, Args)).
-define(wsGLV(Key, List, Default), wsUtil:gLV(Key, List, Default)).

-define(DefWsOpts, [
   binary
   , {packet, raw}
   , {active, false}
   , {reuseaddr, true}
   , {nodelay, true}
   , {delay_send, false}
   , {send_timeout, 15000}
   , {keepalive, true}
   , {exit_on_close, true}
   , {backlog, 4096}
]).

-define(ActionN, 32).

%% HTTP/WebSocket 安全默认值。均可通过 openSrv/2,3 的 WsOpts 覆盖。
-define(DefMaxBodySize, 8 * 1024 * 1024).
-define(DefMaxRequestLineSize, 8 * 1024).
-define(DefMaxHeaderSize, 64 * 1024).
-define(DefMaxWsFrameSize, 1 * 1024 * 1024).
-define(DefMaxWsMessageSize, 8 * 1024 * 1024).

-define(CASE(Cond, Then, That), case Cond of true -> Then; _ -> That end).

-export_type([
   sendfile_opts/0
]).

-type sendfile_opts() :: [{chunk_size, non_neg_integer()}].

-type stage() :: reqLine | wsHeader | wsBody | wsDone | wsWs.       %% 接受http请求可能会有多个包 分四个阶接收
-record(wsState, {
   stage = reqLine :: stage()                                       %% 接收数据阶段
   , buffer = <<>> :: binary()                                      %% 缓存接收到的数据
   , wsReq :: undefined | #wsReq{}                                  %% 解析后的http
   , headerCnt = 0 :: non_neg_integer()                             %% header计数
   , headerBytes = 0 :: non_neg_integer()                           %% 已解析header总字节数
   , hostHeaderSeen = false :: boolean()                            %% 是否收到Host头
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

   , is_behavior = false :: boolean()                         %% 是否是行为连接
   , fragmented = false :: boolean()                                %% websocket
   , fragmentedOpcode :: integer()                                  %% websocket 操作码
   , fragmentedBuffer = [] :: [binary()]                              %% websocket 分片缓存（逆序）
   , fragmentedSize = 0 :: non_neg_integer()                        %% websocket 分片累计长度
   , webState :: term()                                             %% websocket链接状态数据
}).

%% WebSocket握手常量
-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(WS_VERSION, <<"13">>).