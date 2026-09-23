eWSrv
=====

轻量级 Erlang/OTP 29 HTTP Server。

当前支持：

- HTTP/1.0 / HTTP/1.1
- HTTP/2 over TLS（ALPN `h2`）
- HTTP/2 cleartext prior knowledge
- WebSocket over HTTP/1.1
- TLS
- HTTP/1.1 chunked request/response
- HTTP/2 HPACK / Huffman
- HTTP/2 multiplexing
- HTTP/2 connection / stream flow-control
- HTTP/2 streaming response
- HTTP/2 request trailers

HTTP/2 不使用旧的 `Upgrade: h2c` 路径。明文 HTTP/2 客户端使用 prior knowledge。
RFC 8441 WebSocket over HTTP/2 当前没有启用。

Build
-----

```bash
rebar3 compile
rebar3 eunit
```

Usage
-----

```erlang
%% HTTP/1.1 + HTTP/2 prior knowledge，HTTP/2 默认启用。
eWSrv:openSrv(8080, []).

%% 如果只需要 HTTP/1.x。
eWSrv:openSrv(8080, [{http2, false}]).

%% 指定业务 handler。
eWSrv:openSrv(8080, [
    {http2, true},
    {wsMod, wsTPHer}
]).

%% 高吞吐 HTTP/2 场景可以显式调节本端并发 stream 与接收窗口。
%% http2ReceiveWindow 同时作用于 stream 和 connection receive window。
eWSrv:openSrv(8080, [
    {http2, true},
    {wsMod, wsTPHer},
    {http2MaxConcurrentStreams, 256},
    {http2ReceiveWindow, 1024 * 1024}
]).
```

常用限制/性能选项：

| 选项 | 默认值 | 说明 |
| --- | ---: | --- |
| `maxSize` | 8 MB | 单请求 body 上限 |
| `maxRequestLineSize` | 8 KB | HTTP/1 request-line 上限 |
| `maxHeaderSize` | 64 KB | H1/H2 请求头限制 |
| `maxWsFrameSize` | 1 MB | WebSocket 单 frame 上限 |
| `maxWsMessageSize` | 8 MB | WebSocket 完整 message 上限 |
| `requestTimeout` | 30000 ms | 请求处理/接收超时 |
| `keepAliveTimeout` | 60000 ms | 空闲连接超时 |
| `http2MaxConcurrentStreams` | 100 | 本端允许的并发 client streams，并通过 SETTINGS 广播 |
| `http2ReceiveWindow` | 65535 | H2 stream + connection 接收窗口，范围 65535..2^31-1 |
| `chunkedSupp` | false | 是否接受 HTTP/1 chunked request body |

增大 H2 receive window 可以提升高 BDP / 大上传吞吐，但也会增加每条活跃连接/stream 允许在途的数据量；应结合并发数和内存预算一起调。

HTTPS + HTTP/2
--------------

当 `{http2, true}` 时，TLS listener 会使用 ALPN：

```text
h2
http/1.1
```

示例：

```erlang
Priv = code:priv_dir(eWSrv),

eWSrv:openSrv(8443, [
    {http2, true},
    {wsMod, wsTPHer},
    {sslOpts, [
        {certfile, filename:join(Priv, "server_cert.pem")},
        {keyfile, filename:join(Priv, "server_key.pem")}
    ]}
]).
```

支持 `h2` 的客户端会协商 HTTP/2；普通客户端继续走 HTTP/1.1。

HTTP/2 Architecture
-------------------

```text
eNet acceptor
    |
    +-- HTTP/1.x --> wsHttp
    |                 |
    |                 +-- wsHttpProtocol
    |
    +-- HTTP/2 --> wsHttp2
                    |
                    +-- wsHttp2Frame
                    +-- wsHpack
                    +-- wsHpackTable
                    +-- wsHuffman
```

HTTP/1.x 和 HTTP/2 最终都转换为同一个 `#wsReq{}`，因此业务层继续使用：

```erlang
WsMod:handle(Method, Path, WsReq)
```

HTTP/2 请求中：

```erlang
WsReq#wsReq.version = {2, 0}
```

每个 HTTP/2 connection 独立维护：

- HPACK encode/decode context
- connection flow-control window
- stream flow-control window
- stream state
- SETTINGS
- pending DATA

业务 handler 按 stream 使用独立 Erlang worker 执行，因此慢 stream 不会串行阻塞其它 stream。
HPACK 编码和实际 frame 发送仍由 connection owner 统一完成，保证 connection-scoped 状态正确。

Tests
-----

通用测试页面：

```text
http://127.0.0.1:8080/
```

HTTP/2 浏览器专项测试页面：

```text
https://127.0.0.1:8443/http2
```

浏览器通常需要 HTTPS + ALPN 才会真正使用 HTTP/2。
专项页面会通过 Performance API 检查 `nextHopProtocol` 是否为 `h2`。

自动测试：

```bash
rebar3 eunit
```

HTTP/2 测试与 benchmark 详细说明：

```text
test/HTTP2_TESTING.md
```

Performance Benchmark
---------------------

HTTP/1.1：

```erlang
wsHttp1Bench:run().
```

HTTP/2：

```erlang
wsHttp2Bench:run().
```

HTTP/1.1 vs HTTP/2：

```erlang
wsHttpBench:compare().
```

并发矩阵：

```erlang
wsHttpBench:matrix().
```

默认对比口径：

```text
HTTP/1.1 concurrency=N
    = N 条 keep-alive TCP connections

HTTP/2 concurrency=N
    = 1 条 TCP connection + N 个 concurrent streams
```

两边使用相同 handler、相同 path、相同 measured requests、相同 warm-up，
用于比较现实中的 HTTP/1.1 connection pool 与 HTTP/2 multiplexing。

Examples
--------

示例 handler：

```text
src/wsSrv/wsTPHer.erl
```

常用测试：

```text
http://127.0.0.1:8080/
http://127.0.0.1:8080/hello
https://127.0.0.1:8443/http2
```
