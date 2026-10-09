# vellum

vellum 是用 MoonBit 编写的嵌入式键值存储，直接在应用进程里运行。键和值都是 `Bytes`，数据保存在本地页文件中，旁边的 WAL 用于进程中断后的恢复。没有 SQL，也不需要数据库服务。

适合能整体放进内存、由单个句柄管理的本地数据，例如应用设置、工具状态或小型索引。当前磁盘 API 只支持 `native`。

- 用 `get`、`put`、`delete` 读写数据。
- 一次事务可以修改多个键，最后统一 `commit`，或用 `abort` 撤销。
- 重新打开时自动恢复完整已提交的 WAL，并检查页结构。

## 快速开始

在 `moon.mod` 中添加依赖：

```text
import {
  "Nanaloveyuki/vellum@0.3.0",
}
```

调用方的 `moon.pkg`：

```text
import {
  "Nanaloveyuki/vellum",
  "moonbitlang/async",
}
pkgtype(kind: "executable")
```

写入后关掉数据库，再打开读取：

```mbt nocheck
async fn main {
  let db = @vellum.open("notes.db")
  defer db.close()
  let txn = db.begin()
  txn.put(b"hello", b"vellum")
  txn.commit()
  db.close()

  let again = @vellum.open("notes.db")
  defer again.close()
  let read = again.begin()
  match read.get(b"hello") {
    Some(value) => println(value.to_string())
    None => println("missing")
  }
  read.abort()
}
```

运行 `moon run --target native`，输出 `b"vellum"`。父目录必须已经存在；新库在首次有修改的提交时创建。`open/close` 和只读事务不会创建新库文件。

## 事务与错误处理

所有磁盘 API 都是 `async`，失败抛 `DbError`。一个 `Db` 同时只能有一个活动事务；`commit` 或 `abort` 成功后，旧 `Txn` 不能再用，需要重新 `begin`。关闭数据库会丢弃尚未提交的修改。

`put`、`delete` 失败只撤销当前操作，此前成功的修改仍然保留。需要批量写入时，在同一个事务内完成多次操作再提交；批次大小由应用的内存和延迟预算决定。

**提交报错或被取消，不代表写入没有生效。** 提交 I/O 失败或被取消后，句柄进入 `RecoveryRequired`，不能继续读写或 `abort`：

1. 关闭当前 `Db`，不要直接重试提交。
2. 重新打开同一路径，让数据库完成恢复；打开失败时处理该错误。
3. 查询相关键，确认最终状态后再决定下一步操作。

提交过程中不要并发操作同一事务或关闭数据库，否则会得到 `TxnBusy`。提交前取消时，活动事务仍需撤销或关闭；在取消处理代码里可用 `@async.protect_from_cancel(() => txn.abort())` 清理。

常见错误还有 `Closed`、`TxnOpen`、`TxnClosed`、`ValueTooLarge`、`Corrupt` 和 `Io(String)`。`get` 在键不存在时返回 `None`，`delete` 返回是否删除了已有键。

## 使用前须知

- **同一路径只打开一个 `Db`。** 没有文件锁，同一进程或不同进程同时写入会损坏数据；没有并行读快照。
- `open` 会把整个库载入内存并验证结构，内存占用随库大小增长。删除后的空间会复用，但文件不会缩小。
- 固定 4096 字节页。单个 value 最多 4000 字节，且 `key.length() + value.length() <= 4085`；键和值不能跨页，分支分隔键也必须能放进页。超限抛 `ValueTooLarge`。
- 版本 1 的键序是 shortlex：先比较字节长度，长度相同再按字节比较，例如 `b"z"` 在 `b"aa"` 之前。`get` 返回独立拥有的值。
- 主文件与 WAL 都显式同步。恢复覆盖进程中断及日志记录页的部分写入，不能补回日志中没有的缺失页。首次创建的父目录项未同步，尚未验证整机掉电耐久性。
- 数据页没有 CRC，value 的位翻转不一定能检出；WAL 完整帧损坏会报 `Corrupt`，但格式 1 没有事务级页数或摘要，不能保证检出按完整帧边界丢失的日志。恢复不是备份。

`async` 签名不代表每次操作都会让出调度。长循环可在完整操作之间调用 `@async.pause()`，例如每 128 次写入后让其他任务运行；间隔应按实际负载测量。

## 0.3.0

这个版本优化了 CRC、页内查找、节点复用和批量脏页写入。公开 API、错误分支、版本 1 磁盘格式与 shortlex 排序不变；已验证与 0.2.0 双向读写兼容。

本机 Linux/WSL、native release、相同工作负载的三次采样，单位毫秒：

| 工作负载 | 0.2.0 | 0.3.0 |
| --- | ---: | ---: |
| 4096 键、32 字节值：5 万热点查询 | 186–190 | 15–17 |
| 同规模：1 万同值写入 | 74–77 | 16–19 |
| 4096 键、3000 字节值：约 16 MiB 建库提交 | 337–357 | 58–61 |
| 同规模：5 万随机查询 | 275–300 | 64–70 |

这些数字不是吞吐承诺；文件系统、缓存和同步延迟会影响结果。查询与节点缓存有固定容量，页合并写入也有缓冲开销，`open` 仍需载入整个库。可在本机运行基准：

```sh
moon run src/cmd/bench --target native --release
```

基准使用临时目录，覆盖小值与大值、热点与随机访问、不同事务批量及调度心跳，重开后逐键核对数据，结束后删除文件。

## 开发

```sh
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon test --target wasm-gc -p Nanaloveyuki/vellum
```

磁盘测试在 native 运行；wasm-gc 只用于纯页结构与编码测试，不提供浏览器持久化 API。回归覆盖模型对照、跨页修改、撤销、页复用、缓存失效、I/O 故障与取消。

独立进程验证在 WAL 同步后、主文件部分写入后、主文件同步后分别 SIGKILL，再由 0.2.0 和 0.3.0 恢复。六个场景均核对全部 600 条记录，随后成功提交并重开；这不等于整机掉电验证。

## 许可证

[Apache-2.0](LICENSE)。
