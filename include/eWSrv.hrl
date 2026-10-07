-include_lib("eNet/include/eNet.hrl").

-export_type([wsOpt/0]).
-type wsOpt() ::
listenOpt() |                 %% eNet相关配置
{wsMod, module()} |           %% 请求处理的回调模块
{wsSupName, pid() | term()} |            %% ws服务器的supervisor名称
{maxSize, infinity | pos_integer()} |    %% 单次请求Body最大值 默认8MB
{maxRequestLineSize, pos_integer()} |    %% 请求行最大长度 默认8KB
{maxHeaderSize, pos_integer()} |         %% 请求头总大小 默认64KB
{maxWsFrameSize, pos_integer()} |        %% WebSocket单帧最大值 默认1MB
{maxWsMessageSize, pos_integer()} |      %% WebSocket单消息最大值 默认8MB
{http2, boolean()} |                     %% 是否启用HTTP/2（TLS ALPN + 明文prior knowledge）
{http2MaxConcurrentStreams, pos_integer()} | %% 本端允许的HTTP/2并发stream上限 默认100
{http2ReceiveWindow, 65535..2147483647} |    %% H2 stream+connection接收窗口 默认65535
{requestTimeout, pos_integer()} |        %% 单个请求接收超时 默认30秒
{keepAliveTimeout, pos_integer()} |      %% 空闲连接超时 默认60秒
{chunkedSupp, boolean()}.                %% 服务器是否允许客户端发送Transfer-Encoding: chunked 默认false


%% 一次入站 HTTP 请求的解析结果，回调 handle/3 的第三个参数。
%% 示例（HTTP/1.1）：
%%   #wsReq{
%%      method  = 'GET',
%%      path    = <<"/api/user">>,
%%      version = {1, 1},
%%      scheme  = <<"http">>,
%%      host    = <<"127.0.0.1">>,
%%      port    = 8080,
%%      socket  = Sock,
%%      args    = [{<<"id">>, <<"42">>}, {<<"lang">>, <<"zh">>}],
%%      headers = [{'Host', <<"127.0.0.1:8080">>}, {'Accept', <<"*/*">>}],
%%      trailers = [],
%%      body    = <<>>
%%   }
-record(wsReq, {
   method :: wsMethod(),                      %% 请求方法；常见 atom：'GET'|'POST'|'PUT'|'PATCH'|'DELETE'|'HEAD'|'OPTIONS'|'CONNECT'|'TRACE' 也允许自定义 binary，如 <<"PURGE">>；示例：'POST'
   path :: binary(),                          %% 纯路径部分（已去掉 query）；示例：<<"/api/user">>、<<"/">>、<<"*">>（OPTIONS *）
   version :: wsVersion(),                    %% HTTP 版本元组 {Major, Minor}；子类：{0, 9} | {1, 0} | {1, 1} | {2, 0}（见 wsVersion/0）
   scheme :: undefined | binary(),            %% URL 协议；H1 由 TLS/明文推断，H2 来自 :scheme 示例：<<"http">> | <<"https">>；绝对 URI 请求时也可能是 <<"ws">>/<<"wss">>；未知为 undefined
   host :: undefined | binary(),              %% 目标主机名/IP（不含端口）；H1 来自 Host 头或绝对 URI，H2 来自 :authority 示例：<<"example.com">> | <<"127.0.0.1">>；未解析到时为 undefined
   port :: undefined | 1..65535,              %% 目标端口；未显式给出时按 scheme 默认（http→80，https→443）或监听端口推断 示例：8080 | 443；未知为 undefined
   socket :: inet:socket() | ssl:sslsocket(), %% 当前连接底层 socket，可用于 peername/sockname 等；示例：gen_tcp 或 ssl 句柄
   args :: [{binary(), any()}],               %% URL query 解析后的键值列表（同名 key 可重复出现）；值多为 binary 请求 /search?q=hi&page=1 → [{<<"q">>, <<"hi">>}, {<<"page">>, <<"1">>}]；无 query 时为 []
   headers :: wsHeaders(),                    %% 请求头列表 [{Key, Value}, ...]；H1 常见名为 atom，H2/自定义多为小写 binary 示例：[{'Content-Type', <<"application/json">>}, {<<"x-request-id">>, <<"abc">>}]
   trailers = [] :: wsHeaders(),              %% 请求 trailer（chunked / H2 END_STREAM 后附带的尾部头）；默认 [] 示例：[{<<"x-checksum">>, <<"sha256-...">>}]；多数请求无 trailer
   body = <<>> :: wsBody()                    %% 请求体，binary 或 iolist；GET/HEAD 等通常为 <<>> 示例：<<"{\"name\":\"tom\"}">> | [<<"part1">>, <<"part2">>]
   
}).

-export_type([
   wsReq/0
   , wsMethod/0
   , wsBody/0
   , wsPath/0
   , wsHeaders/0
   , wsHttpCode/0
   , wsVersion/0
   , header_key/0
   , wsSocket/0
   , wsOpCode/0
]).

-type wsReq() :: #wsReq{}.
-type wsMethod() :: 'OPTIONS' | 'GET' | 'HEAD' | 'POST' | 'PUT' | 'PATCH' | 'DELETE' | 'CONNECT' | 'TRACE' | binary().
-type wsBody() :: binary() | iolist().
-type wsPath() :: binary().
%% H1 decode_packet 会把常见字段名表示成 atom，H2/自定义字段通常是 binary；
%% 响应层同时接受常见的 integer/atom value 并在上线路前转成 binary。
-type wsHeader() :: {Key :: header_key(), Value :: binary() | string() | integer() | atom()}.
-type wsHeaders() :: [wsHeader()].
-type wsHttpCode() :: 100..999.
-type wsVersion() :: {0, 9} | {1, 0} | {1, 1} | {2, 0}.
-type wsSocket() :: inet:socket() | ssl:sslsocket().


%% WebSocket帧类型
-define(WsOpCF, 16#0).                                               %% 表示一个继续帧（Continuation Frame）
-define(WsOpText, 16#1).
-define(WsOpBinary, 16#2).
-define(WsOpClose, 16#8).
-define(WsOpPing, 16#9).
-define(WsOpPong, 16#A).

-type wsOpCode() :: ?WsOpCF | ?WsOpText | ?WsOpBinary | ?WsOpClose | ?WsOpPing | ?WsOpPong.

%% http header 头
-type header_key() ::
'Cache-Control' |
'Connection' |
'Date' |
'Pragma'|
'Transfer-Encoding' |
'Upgrade' |
'Via' |
'Accept' |
'Accept-Charset'|
'Accept-Encoding' |
'Accept-Language' |
'Authorization' |
'From' |
'Host' |
'If-Modified-Since' |
'If-Match' |
'If-None-Match' |
'If-Range'|
'If-Unmodified-Since' |
'Max-Forwards' |
'Proxy-Authorization' |
'Range'|
'Referer' |
'User-Agent' |
'Age' |
'Location' |
'Proxy-Authenticate'|
'Public' |
'Retry-After' |
'Server' |
'Vary' |
'Warning'|
'Www-Authenticate' |
'Allow' |
'Content-Base' |
'Content-Encoding'|
'Content-Language' |
'Content-Length' |
'Content-Location'|
'Content-Md5' |
'Content-Range' |
'Content-Type' |
'Etag'|
'Expires' |
'Last-Modified' |
'Accept-Ranges' |
'Set-Cookie'|
'Set-Cookie2' |
'X-Forwarded-For' |
'Cookie' |
'Keep-Alive' |
'Proxy-Connection' |
binary() |
string().
