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

| 选项                          |      默认值 | 说明                                           |
|-----------------------------|---------:|----------------------------------------------|
| `maxSize`                   |     8 MB | 单请求 body 上限                                  |
| `maxRequestLineSize`        |     8 KB | HTTP/1 request-line 上限                       |
| `maxHeaderSize`             |    64 KB | H1/H2 请求头限制                                  |
| `maxWsFrameSize`            |     1 MB | WebSocket 单 frame 上限                         |
| `maxWsMessageSize`          |     8 MB | WebSocket 完整 message 上限                      |
| `requestTimeout`            | 30000 ms | 请求处理/接收超时                                    |
| `keepAliveTimeout`          | 60000 ms | 空闲连接超时                                       |
| `http2MaxConcurrentStreams` |      100 | 本端允许的并发 client streams，并通过 SETTINGS 广播       |
| `http2ReceiveWindow`        |    65535 | H2 stream + connection 接收窗口，范围 65535..2^31-1 |
| `chunkedSupp`               |    false | 是否接受 HTTP/1 chunked request body             |

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

wrk性能

```
wrk -t4 -c200 -d30s --latency http://127.0.0.1:8080/hello
Running 30s test @ http://127.0.0.1:8080/hello
  4 threads and 200 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.28ms  801.81us  26.20ms   86.33%
    Req/Sec    40.70k     4.69k   61.34k    66.67%
  Latency Distribution
     50%    1.15ms
     75%    1.53ms
     90%    1.98ms
     99%    4.24ms
  4862003 requests in 30.03s, 361.67MB read
Requests/sec: 161885.63
Transfer/sec:     12.04MB

```

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

性能：`+IOt`（仅 Windows 需要）
------------------------------

Windows 上 ERTS 的轮询后端（`erts/emulator/sys/win32/erl_poll.c`）不支持并发更新：
每处理完一个 I/O 事件，要让 fd 重新可被监听，都得走一遍
「停轮询线程 → 改 handle 数组 → 放行线程」的握手。
**这个串行点是 per-pollset 的，而默认只有 1 个 pollset。**

`+IOt N` 会创建 N 个独立 pollset，握手随之并行。本机实测（Windows / 32 核，oha，
每连接串行一去一回，200 并发，3 轮、成功率 100%）：

| 启动参数        |    QPS | 平均延迟 |
|-------------|-------:|------:|
| 默认（1 个 pollset） |  56.8k | 3.51 ms |
| `+IOt 8`    | **154k** | **1.30 ms** |

每请求真实 CPU 基本不变（10.74 → 10.44 µs/req）—— 这不是拿核换吞吐，而是解除了串行点。

escript 产物（`rebar3 escriptize`）已在 `rebar.config` 的 `escript_emu_args` 中带上
`+IOt 8`；直接用 `erl` 启动时自行追加即可：

```bash
erl +sbtu +A0 +IOt 8 -pa _build/default/lib/eWSrv/ebin ...
```

注意事项：

- **只对「每连接串行一去一回」(K≈1) 有效。** HTTP/1.1 管道或 HTTP/2 多 stream
  让请求批量在飞，已经绕开了同一条路径，实测 `+IOt` 无影响（管道 1.96M vs 1.85M，噪声内）。
- **饱和点是 8**（16 不再涨）；并发 400 时 `+IOt 8` 回落到 2.0×。
  **换机器、换并发请重新实测再定值。**
- Windows 的 waiter 线程池永不收缩，`+IOt` 会常驻更多轮询线程
  （每 64 个 handle 一个 waiter）。
- 这组数字来自 loopback 同机压测。完整数据与根因分析见
  `docs/PERF_WINDOWS_IOT_POLLSET_20260927.md`。

### Linux / macOS 上不要照抄 `+IOt 8`

这个开关解的是 **Windows 独有**的那个串行点，Linux 上不存在，照抄大概率**无效**
（甚至因多开 7 个常驻轮询线程而轻微变差）。原因是两条分支在源码里就是分开的
（`erts/emulator/sys/common/erl_poll.c`）：

```c
#define ERTS_POLL_USE_CONCURRENT_UPDATE (ERTS_POLL_USE_EPOLL || ERTS_POLL_USE_KQUEUE)
```

- **Linux（epoll）/ macOS（kqueue）走并发分支**：`erts_poll_control` 直接改内核
  pollset（`epoll_ctl`），**不设 `*do_wake`**，`wake_poller()` 直接返回，**且完全不加锁**。
  ⇒ 没有「停线程 / 唤醒线程」这一步，`+IOt` 无从可解。
- **Windows 走非并发分支**：`*do_wake = 1` + 入 update 队列 + 唤醒等待线程 + mutex。

另一个独立证据是 `+IOp`（pollset 数）：官方说明它「只在支持并发更新的平台上生效，
否则 pollset 数等于轮询线程数」。本机实测与之一致 —— Windows 上 `+IOp 8` 得到
**1 个** pollset（被忽略），`+IOt 8` 得到 8 个；`+IOt 2 +IOp 4` 得到 2 个。
**⇒ 在 Linux 上 pollset 数由 `+IOp` 决定（默认 1），`+IOt` 只增加事件投递线程数。**

Linux 上的判据不是照抄参数，而是看 poll 线程本身是否成为瓶颈：

```bash
# 1. 确认走的是并发更新（kernel_poll=true、concurrent_updates=true）
erl -noshell -eval 'io:format("~p~n",[erlang:system_info(check_io)]),halt().'
# 2. 看 poll 线程的负载：sleep 占比很低才值得加线程
erl -noshell -eval 'msacc:start(10000),timer:sleep(10000),msacc:print(),halt().'
```

若确认要调，Linux 上正确的旋钮是 `+IOp`（拆 pollset）而不是 `+IOt`；
用户实测 Linux 4 核默认即为 161,885 req/s，与 Windows 加了 `+IOt 8` 后的量级相当
⇒ **Linux 默认就处在「没有这个串行点」的状态，没有 3× 的上行空间。**

