# eWSrv HTTP/2 测试与性能基准

本分支的 HTTP/2 测试分三层，全部不依赖 Cowboy/Cowlib。

## 1. 自动协议测试

运行：

```bash
rebar3 eunit
```

核心模块：`test/wsHttp2Unit.erl`

当前覆盖包括：

- HTTP/2 prior knowledge preface + SETTINGS
- TLS ALPN `h2`
- SETTINGS / ACK
- HPACK 编解码
- RFC 7541 HPACK 互操作向量
- RFC 7541 Huffman 互操作向量
- frame 任意拆包 / 逐字节输入
- HEADERS + CONTINUATION
- DATA request body
- multiplexing
- slow stream 不阻塞 fast stream
- request timeout
- idle GOAWAY
- RST_STREAM / closed stream 行为
- send flow-control
- compression
- HTTP/1 handler compatibility
- HTTP 205 no-body semantics

## 2. 浏览器 HTTP/2 专项测试页

启动 TLS listener，并开启 HTTP/2：

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

浏览器访问：

```text
https://127.0.0.1:8443/http2
```

注意：浏览器通常不会通过明文 HTTP 自动使用 h2c prior-knowledge，因此浏览器测试应使用 HTTPS + ALPN。

页面会通过 `PerformanceNavigationTiming.nextHopProtocol` 和
`PerformanceResourceTiming.nextHopProtocol` 检查是否真正协商为 `h2`。

专项页面包括：

- ALPN / h2 探测
- GET / POST
- multiplexing
- Burst QPS
- p50 / p95 / p99
- 大响应吞吐
- 大请求体 echo
- streaming DATA
- Abort / RST_STREAM 后连接存活
- gzip / deflate

原有 `/` 测试中心也增加了“HTTP/2 专项”入口。

## 3. 本机 HTTP/2 性能基准

基准模块：

```text
test/wsHttp2Bench.erl
```

进入 test shell：

```bash
rebar3 as test shell
```

默认：

```erlang
wsHttp2Bench:run().
```

默认参数：

- 10,000 requests
- 32 concurrent streams
- 单 TCP connection
- HTTP/2 prior knowledge
- 本机 loopback
- 路径 `/one`

自定义：

```erlang
wsHttp2Bench:run(#{
    requests => 50000,
    concurrency => 64,
    path => <<"/one">>
}).
```

输出：

```text
requests
concurrency
total ms
requests/sec
latency avg
latency p50
latency p95
latency p99
```

该 benchmark 故意使用单 connection + 多 stream，主要衡量 HTTP/2 multiplexing、
HPACK、frame parser、stream state、handler worker 和 response DATA path 的开销。

正式比较 HTTP/1.1 与 HTTP/2 时，建议同时使用 eWCli benchmark，以保持客户端实现、
机器、payload 和测试方法一致。
