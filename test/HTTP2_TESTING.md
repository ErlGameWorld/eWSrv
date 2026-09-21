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


## 4. HTTP/1.1 对照性能基准

HTTP/1.1 benchmark：

```erlang
wsHttp1Bench:run().
```

默认参数：

- 10,000 measured requests
- 1,000 warm-up requests
- 32 条 keep-alive TCP connections
- 每连接同一时刻最多 1 个 in-flight request
- 与 HTTP/2 使用相同的 `wsHttp2TestHandler`
- 默认路径同为 `/one`

自定义：

```erlang
wsHttp1Bench:run(#{
    requests => 50000,
    concurrency => 64,
    warmup => 5000,
    path => <<"/one">>
}).
```

输出字段与 `wsHttp2Bench` 完全一致：

- requests/sec
- total time
- average latency
- p50
- p95
- p99

### H1 与 H2 一键对比

```erlang
wsHttpBench:compare().
```

或：

```erlang
wsHttpBench:compare(#{
    requests => 50000,
    concurrency => 32,
    warmup => 5000,
    path => <<"/one">>
}).
```

公平性口径：

| 参数 | HTTP/1.1 | HTTP/2 |
| --- | --- | --- |
| concurrency=N | N 条 keep-alive connection | 1 条 connection 上 N 个 stream |
| handler | wsHttp2TestHandler | wsHttp2TestHandler |
| path | 相同 | 相同 |
| measured requests | 相同 | 相同 |
| warm-up | 相同 | 相同 |
| 网络 | localhost loopback | localhost loopback |

这样比较的是现实中常见的 **HTTP/1.1 connection pool vs HTTP/2 multiplexing**。

### 并发矩阵

一次跑多个并发点：

```erlang
wsHttpBench:matrix().
```

默认：

```text
1 / 8 / 16 / 32 / 64
```

也可以：

```erlang
wsHttpBench:matrix(#{
    requests => 20000,
    warmup => 2000,
    concurrencies => [1, 4, 8, 16, 32, 64, 100],
    path => <<"/one">>
}).
```

矩阵输出可以直接观察：

- H1 connection pool 扩展曲线
- H2 multiplexing 扩展曲线
- H2/H1 throughput ratio
- 两边 p95 latency

建议正式性能报告至少测：

```text
small response: /one
large response: /large
concurrency:    1 / 8 / 16 / 32 / 64 / 100
requests:       >= 50,000
warmup:         >= 5,000
repeat:         >= 3 runs
```

并分别记录：

- req/s
- avg / p50 / p95 / p99
- CPU usage
- scheduler utilization
- process count
- memory / binary memory
- reductions
- network bytes

对于 TLS，还应再做一组 HTTPS/ALPN h2 对比 HTTPS/HTTP/1.1，因为 TLS record、ALPN 与加密成本会改变实际结果。
