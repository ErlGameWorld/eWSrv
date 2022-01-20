-include_lib("eNet/include/eNet.hrl").

-export_type([wsOpt/0]).
-type wsOpt() ::
   listenOpt() |                 %% eNet相关配置
   {wsMod, module()} |           %% 请求处理的回调模块
   {maxSize, infinity | pos_integer()} |    %% 单次请求Content-Length的最大值 默认值 infinity
   {chunkedSupp, boolean()}.                %% 服务器是否运行客户端发送Transfer-Encoding 默认不运行 主要是为了防攻击


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
]).

-type wsReq() :: #wsReq{}.
-type wsMethod() :: 'OPTIONS' | 'GET' | 'HEAD' | 'POST'| 'PUT' | 'DELETE' | 'TRACE' | binary().
-type wsBody() :: binary() | iolist().
-type wsPath() :: binary().
-type wsHeader() :: {Key :: binary(), Value :: binary() | string()}.
-type wsHeaders() :: [wsHeader()].
-type wsHttpCode() :: 100..999.
-type wsVersion() :: {0, 9} | {1, 0} | {1, 1}.
-type wsSocket() :: inet:socket() | ssl:sslsocket().

-define(CONTENT_LENGTH_HEADER, 'Content-Length').
-define(CONNECTION_HEADER, 'Connection').
-define(TRANSFER_ENCODING_HEADER, 'Transfer-Encoding').
-define(EXPECT_HEADER, <<"Expect">>).

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
