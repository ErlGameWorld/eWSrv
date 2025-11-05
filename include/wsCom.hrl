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

-define(ActionN, 128).

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
   , headerCnt = 0 :: pos_integer()                                 %% header计数
   , temHeader = [] :: [wsHeaders()]                                  %% 解析header临时数据
   , contentLength :: undefined | non_neg_integer() | chunked       %% 长度
   , temChunked = <<>> :: binary()                                  %% chunked 模式下保存数据
   , method :: wsMethod()                                             %% 请求的method
   , path :: binary()                                               %% 请求的URL
   , rn :: undefined | binary:cp()                                  %% binary:cp()
   , socket :: undefined | inet:socket() | ssl:sslsocket()          %% 连接的socket
   , isSsl = false :: boolean()                                     %% 是否是ssl
   , wsMod :: module()                                              %% 回调请求的模块
   , maxSize = infinity :: pos_integer()                            %% 单次允许接收的最大长度
   , chunkedSupp = false :: boolean()                               %% 是否运行 chunked

	, fragmented = false :: boolean()     									  %% websocket
	, fragmentedOpcode :: integer()											  %% websocket 操作码
	, fragmentedBuffer = <<>> :: binary()                            %% websocket 中间缓存数据
	, webState :: term()															  %% websocket链接状态数据
}).

%% WebSocket握手常量
-define(WS_GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(WS_VERSION, <<"13">>).