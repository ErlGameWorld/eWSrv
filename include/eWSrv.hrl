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
{requestTimeout, pos_integer()} |        %% 单个请求接收超时 默认30秒
{keepAliveTimeout, pos_integer()} |      %% 空闲连接超时 默认60秒
{chunkedSupp, boolean()}.                %% 服务器是否允许客户端发送Transfer-Encoding: chunked 默认false


-record(wsReq, {
   method :: wsMethod(),
   path :: binary(),
   version :: wsHttp:wsVersion(),
   scheme :: undefined | binary(),
   host :: undefined | binary(),
   port :: undefined | 1..65535,
   socket :: inet:socket() | ssl:sslsocket(),
   args :: [{binary(), any()}],
   headers :: wsHeaders(),
   trailers = [] :: wsHeaders(),
   body = <<>> :: wsBody()
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
-type wsHeader() :: {Key :: atom(), Value :: binary() | string()}.
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
