# eWSrv P0/P1/P2 审核与全项目性能优化（2026-09-23）

分支：`perf/p0-p2-audit-20260923`  
基线：`main@f75fd73dfc1867ad2a45cb6e2759ab72d65cd3bc`  
目标运行时：Erlang/OTP 29

## 1. 审核目标

本轮不是针对 `/hello` 做特化，而是按整个 eWSrv 的稳态成本审核：

- HTTP/1.0 / HTTP/1.1 请求解析、keep-alive、pipeline、chunked、file/sendfile、压缩
- HTTP/2 frame、HPACK/Huffman、多路复用、flow-control、stream worker、streaming/file
- WebSocket 握手、frame 增量解析、mask/unmask、fragmentation、发送路径
- TLS/ALPN 与 cleartext prior-knowledge
- 连接进程 mailbox、timer、短命 binary/list/map、重复扫描和不必要复制
- 请求边界、安全限制和异常关闭路径

用户提供的历史 HTTP/1 `wrk -t4 -c200 -d30s --latency` 结果用于观察性能回归，但不作为实现约束：

| 版本/阶段 | Requests/sec | Avg latency | p99 |
| --- | ---: | ---: | ---: |
| 早期 HTTP/1 版本 | 142458.39 | 1.44 ms | 4.12 ms |
| 回退阶段 | 92763.06 | 2.17 ms | 4.72 ms |
| 近期恢复阶段 | 131843.25 | 1.54 ms | 3.84 ms |

最终是否超过早期结果，必须以同机器、同 OTP、同 eNet、同 CPU governor、同请求内容的复测为准。

---

## 2. P0 / P1 / P2 结论

### P0

本轮静态审计后，没有确认仍未修复的 P0 级问题。

已有代码本身已具备的重要防护包括：

- HTTP/1 Content-Length 冲突检查
- Content-Length + Transfer-Encoding 冲突检查
- request-line/header/body/frame/message 大小上限
- HTTP/1.1 Host 必需/重复 Host 检查
- H2 continuation/header block 限制
- H2 flow-control 溢出检查
- H2 rapid-reset / frame-rate 类限制
- WebSocket mask、control frame、UTF-8、frame/message 大小检查

注意：这里的“无确认 P0”是静态审核结论，不等价于经过 fuzz / property test 后证明不存在 P0。

### P1：本分支已修

1. **HTTP/1 chunk streaming mailbox 可无界增长**
   - 原实现 stream 期间不断重新 `{active, ?ActionN}`。
   - 客户端持续发送 pipeline 数据时，未匹配的 `{tcp,...}` / `{ssl,...}` 可持续堆积。
   - 改为 stream 期间 `{active,1}`，最多预读一个数据包，随后保持 passive 形成内核背压；stream 结束恢复正常 active-N。

2. **HTTP/1 CONNECT / PATCH request method 与 request-target 解析不完整**
   - OTP 的 `decode_packet(http_bin,...)` 对未内建 method 可返回 binary。
   - 现在显式规范化 PATCH/CONNECT。
   - 支持 OPTIONS `*`、CONNECT authority-form，并拒绝不合法 asterisk-form。

3. **HTTP/1 chunked request trailers 过去直接丢弃**
   - 现在解析、限制大小/数量、拒绝 framing/hop-by-hop trailer。
   - 新增 `#wsReq.trailers` 与 `eWSrv:trailers/1`。
   - H2 也暴露独立 trailers；为兼容旧代码，目前 H2 仍保留旧的 headers 合并行为。

4. **HTTP/1 unsupported Expect 被静默忽略**
   - `100-continue` 正常处理。
   - 有 body 的 unsupported expectation 返回 417，避免客户端/服务器互等导致超时。

5. **HTTP/1 send error 分类与现有测试语义不一致**
   - 成功路径无日志。
   - peer-gone 类错误记 warning 并原样返回 error。
   - 其他 send error 记 error。

6. **WebSocket handshake header 名匹配不够稳健**
   - `Sec-WebSocket-*` 等字段改为真正大小写不敏感匹配。

7. **HTTP/2 streaming response 绕过响应 header-list 限制**
   - 普通 response 会检查本地 `maxHeaderSize` 与 peer `SETTINGS_MAX_HEADER_LIST_SIZE`。
   - 原 streaming/chunk response 在 `handleStreamStart` 直接进入 HPACK 编码和发送，形成限制绕过。
   - 现在与普通响应使用同一限制，并在 HPACK 编码前拒绝超大 header，避免额外 CPU/内存开销。

8. **HTTP/2 调优参数链一度不完整**
   - `eWSrv/wsHttp` 已传入 `http2MaxConcurrentStreams/http2ReceiveWindow`，但 `wsHttp2` 缺少对应 `new/8`。
   - 已补齐完整参数链与旧 `new/6` 兼容入口。
   - `http2ReceiveWindow > 65535` 现在同时通过 SETTINGS 调整 stream window，并通过 stream-id 0 的 WINDOW_UPDATE 调整 connection receive window；避免“stream 窗口变大但连接仍卡 64KB”的假优化。

### P2：已补或仍明确存在

已补：

- WebSocket `supportedProtocols/0` 过去是空壳接口；现在升级时真正进行 subprotocol negotiation。
- H1 absolute-form 未显式端口时统一得到默认 80/443。
- request trailers 提供独立公共 API。

仍明确未启用/未做：

- RFC 8441 WebSocket over HTTP/2：仍未启用。
- WebSocket extension negotiation：`supportedExtensions/0` 仍只是预留。没有扩展 frame 语义前不应仅回显扩展名。
- HTTP/1 chunked **response trailers** 没有一等 API。
- CONNECT 现在能正确解析 authority-form，但 eWSrv 没有内建“切换为通用 tunnel transport”的高级 API；业务 handler 仍需自行定义应用语义。
- h2c Upgrade 路径未实现；cleartext HTTP/2 使用 prior knowledge。当前 README 已明确。
- H2 legacy trailer-to-headers merge 为兼容保留；未来大版本可只保留 `trailers` 字段。

---

## 3. 全项目性能修改

### 3.1 连接 / 调度层

- socket active-N 默认恢复为 128，减少高 QPS HTTP/1 下 `tcp_passive -> setopts` 往返。
- request timeout 的 monotonic clock 不再对每个完整单包请求固定读取；只有请求需要等待后续数据时才启动计时。
- chunk streaming 期间限制预读，防止 mailbox 膨胀同时保留 backpressure。

### 3.2 HTTP/1 请求解析

- origin-form 使用专用解析：
  - 普通 path 不再进入通用 `uri_string:parse/1`
  - query 只做必要拆分/解码
  - fragment 明确拒绝
- Host/authority 使用 `binary:match`，避免全局 split 临时列表。
- Connection token 在读请求头时只解析一次，响应阶段直接使用缓存语义。
- 单 segment request body 直接复用 binary，不再 `reverse + iolist_to_binary` 复制。
- origin-form 带 query 时也改为 `binary:match/2 + binary pattern` 定位，避免 `binary:split/2` 临时列表。

### 3.3 HTTP/1 响应

普通 response、chunk response、file/sendfile 共用单遍 header preparation：

- 规范化 header name/value
- 安全校验
- 去除框架自管 Content-Length / Transfer-Encoding
- 提取 response Connection 语义
- 后续使用已验证 header 的 prepared serializer

避免原先对同一组 header 多轮 normalize / filter / find / validate。

其他：

- body 长度只计算一次并沿响应流程传递。
- prepared file header 不再重复走通用 header 校验。
- compression negotiation 改为直接命中标准 Accept-Encoding + 单遍解析 gzip/deflate/* q-value，避免整串 lowercase 和多组临时列表。

### 3.4 HTTP/2 frame / flow-control / stream

- `wsHttp2Frame:frame/4` 保持 payload 为 iodata，不再先 `iolist_to_binary` 整体复制。
- DATA / HEADERS continuation 分帧不再构造 `length + seq + zip` 临时列表。
- 收包 flow-control credit 只更新本批真正有 credit 的 stream，不再每个 recv batch `maps:map` 扫描所有 open streams。
- connection WINDOW_UPDATE / peer SETTINGS 只 flush 真正 send-pending 的 stream，不再遍历全部 stream。
- 大响应 timer 从“每个 DATA frame cancel/re-arm”改为“每个发送 burst / 文件 buffer 粒度刷新”。
- H2 header byte size + header count 合并一次遍历。
- Content-Length request validation 改成单遍。
- response normalization 同一遍剔除框架自管 content-length。
- authority parser 避免全局 split 临时列表。
- 单 frame request body 不再复制。
- H2 request 普通 header 的 field-value 不再在同一解析路径重复扫描两遍。
- 无 query 的 `:path` 使用 `binary:match/2` 快路径，避免 `binary:split/2` 临时列表。
- 单帧 HPACK response block 保持 iodata 直接发送；只有真正需要 CONTINUATION 时才扁平化。
- 单帧 HEADERS 已知 HPACK block 长度后直接构造 frame header，不再二次 `iolist_size/1`。
- `http2MaxConcurrentStreams` 同时用于 SETTINGS 广播和本地 stream admission enforcement。
- `http2ReceiveWindow` 同时覆盖 stream/connection 两级接收窗口。

### 3.5 HPACK / Huffman

HPACK：

- 新增内部 `encodeLower/2`：H2 response layer 已经把 header name 规范化为 lowercase binary 后，HPACK 不再重复逐字节检查一次。
- 公共 `encode/2` 保留防御性 normalize 语义，避免破坏 API。
- 编码循环改为显式递归，减少通用 mapfold closure 路径。

Huffman：

- 本轮没有强行重写生成表或把“两遍 size+encode”改成“一定先编码”。
- 原因：对不适合 Huffman 的短字符串，先生成编码结果再丢弃可能是负优化。
- 这部分应由 HPACK header corpus benchmark 决定，而不是仅凭代码形态改写。

### 3.6 异常路径 / 运维稳定性

- H1/H2 handler 非法返回或异常时不再把完整 `#wsReq{}`（尤其大 body）格式化进日志。
- WebSocket handler 非法返回时不再把完整长期 `WebState` 格式化进日志。
- 日志保留 method/path/version/header count/body size、返回值形态以及有界深度 exception/stack。
- 目的不是提高正常请求 benchmark，而是避免错误风暴把一次业务异常放大成大对象格式化、日志 IO 和内存压力。

### 3.7 WebSocket

接收：

- 大帧 unmask 不再每 4 bytes 分配一个小 binary + cons cell。
- 使用 32-bit binary comprehension 构造目标 binary，并单独处理 0~3 byte tail。

发送：

- `sendFrame/3` 改为内部 iodata `[FrameHeader, Payload]` 直接发 socket。
- binary / continuation frame 可直接接受业务 iodata，通过 `iolist_size/1` 编码长度，不再先整体 flatten。
- text/control frame 因 UTF-8、close-code、125-byte control limit 校验仍规范成 binary。
- 大 payload 不再为了 frame 再复制进一个完整新 binary。
- 公共 `encodeFrame/2` 仍返回单 binary，保持 API 兼容。

握手：

- header field-name case-insensitive。
- 接通 `supportedProtocols/0` 子协议协商。

---

## 4. 为什么这些不是 /hello 特化

本分支优化覆盖：

| 工作负载 | 主要受益点 |
| --- | --- |
| 小 GET/JSON API | H1 parser、Connection 缓存、单遍 response headers、timer |
| POST/PUT/PATCH | 单 segment body、method normalize、header parser |
| 大 response | H1 prepared response、H2 iodata frame、flow-control、timer |
| 文件下载 | H1 sendfile prepared headers、H2 file buffer + pending stream flush |
| chunk/stream | H1 mailbox backpressure、H2 pending stream set |
| gzip/deflate | Accept-Encoding 单遍解析 |
| H2 高并发 streams | sparse credit、send-pending set、header accounting |
| WebSocket 小消息 | 握手与状态机保持轻量 |
| WebSocket 大消息 | unmask 分配减少、发送 payload 零额外整帧复制 |
| TLS | 上述 H1/H2/WS 数据路径同样复用 |

---

## 5. Benchmark 代码本身的修正

`wsHttp2TestHandler:/large` 原来每个请求执行：

`binary:copy(<<"x">>, 100000)`

这会把 handler 的 100KB 分配成本混进 HTTP server benchmark。

现在 benchmark payload 在 warm-up 时缓存，并增加：

- `/1k`
- `/large` = 100KB
- `/1m`

HTTP/1 内置 bench 也不再强制把 concurrency 截断为 100，因此可以直接测 200/256/512 connections。

---

## 6. 推荐验证方法

### 6.1 编译与回归

在 OTP29 环境：

```bash
git checkout perf/p0-p2-audit-20260923
rebar3 compile
rebar3 eunit
```

本轮已新增/扩展测试覆盖：

- H1 query/origin-form
- OPTIONS asterisk
- CONNECT authority-form
- PATCH normalize
- Connection token
- H1 chunk trailer
- unsupported Expect
- WebSocket header casing
- WebSocket subprotocol
- H2 nested iodata frame
- H2 single-frame HPACK iodata path
- H2 normalized HPACK fast path
- H2 streaming response header-list limit
- H2 configurable stream/connection receive window + max concurrent SETTINGS
- stream 期间到达 pipeline request
- 原有 H2 flow-control / reset / timeout / streaming 回归

### 6.2 内置 H1/H2 同口径

推荐至少：

```erlang
wsHttpBench:compare(#{
    requests => 100000,
    warmup => 10000,
    concurrency => 32,
    path => <<"/one">>
}).

wsHttpBench:matrix(#{
    requests => 100000,
    warmup => 10000,
    path => <<"/one">>,
    concurrencies => [1, 8, 16, 32, 64, 100]
}).
```

再分别跑：

- `/1k`
- `/large`
- `/1m`

说明：H1 concurrency=N 是 N 条 keep-alive TCP connections；H2 concurrency=N 是 1 条 TCP connection 上 N 个 concurrent streams。

### 6.3 外部 HTTP/1

测试服务建议使用 `wsHttp2TestHandler`，避免 demo handler 业务逻辑污染：

```erlang
eWSrv:openSrv(bench, 8080, [
    {http2, true},
    {wsMod, wsHttp2TestHandler},
    {keepAliveTimeout, 300000}
]).
```

```bash
wrk -t4 -c200 -d60s --latency http://127.0.0.1:8080/one
wrk -t4 -c200 -d60s --latency http://127.0.0.1:8080/1k
wrk -t4 -c200 -d60s --latency http://127.0.0.1:8080/large
wrk -t4 -c200 -d60s --latency http://127.0.0.1:8080/1m
```

### 6.4 外部 HTTP/2

当前 h2load 对 cleartext `http://` 默认使用 h2c prior-knowledge，可直接：

```bash
h2load -t4 -c1  -m32  -D60 --warm-up-time=10 http://127.0.0.1:8080/one
h2load -t4 -c1  -m100 -D60 --warm-up-time=10 http://127.0.0.1:8080/one
h2load -t4 -c10 -m100 -D60 --warm-up-time=10 http://127.0.0.1:8080/large
```

要测 flow-control，而不是让 h2load 的超大窗口几乎绕开流控，还应增加较小的 `-w/-W` 组合单独跑一轮。

### 6.5 WebSocket

至少覆盖 payload：

- 1KB
- 16KB
- 64KB
- 1MB
- fragmented 1MB

分别记录：

- messages/s
- MB/s
- avg / p50 / p95 / p99
- server reductions/s
- process memory / binary memory
- scheduler utilization

这样才能验证 unmask / iodata send 的收益，而不是只测 handshake。

---

## 7. 结果记录标准

每组：

- warm-up 10~20s
- 正式 60s 以上
- 至少 5 次
- 取中位数
- 测试期间不要同时编译/跑 EUnit
- 固定 OTP29、eNet revision、CPU governor/频率策略

记录：

- req/s 或 msg/s
- transfer MB/s
- avg / p50 / p95 / p99 / p99.9
- failed / errored / timeout / disconnect
- CPU
- Erlang reductions/s
- scheduler utilization
- process memory
- binary memory
- process count

只有在这些维度没有明显回退时，才应该把优化分支合回 main。

---

## 8. 当前验证状态

已完成：

- main 全量静态审计
- 一个独立最终优化分支
- H1/H2/WS/HPACK/stream/file/compression 多处代码级优化
- 功能边角补齐与新增回归测试
- 分支保持 main 不变

当前工具环境限制：

- 没有 Erlang/OTP 与 rebar3 可执行文件
- 因此这里不能真实声明 `rebar3 compile` / `rebar3 eunit` 已全绿
- 也没有在你的 Rocky Linux 压测机上执行真实 wrk/h2load

所以 promotion gate 必须是：

**OTP29 compile → EUnit → H1/H2/WS 功能回归 → 外部 wrk/h2load → 与 main 同机 A/B → 再合并。**

不要只看 `/hello`；最终判定必须同时看 small/large/file/stream/WS/H2 multiplexing。
