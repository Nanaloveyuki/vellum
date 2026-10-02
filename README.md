# vellum

MoonBit 进程里的单文件页存储。`commit` 把数据写进页文件；中途崩溃的话，下次 `open` 用旁边的 WAL 把已经提交的部分补回去。

键和值都是 `Bytes`。没有 SQL，也不开网络端口。

## 依赖

`moon.mod`：

```
import {
  "Nanaloveyuki/vellum@0.1.0",
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

用 `moon run --target native` 运行。磁盘 API 只在 `native` 导出；其他后端仅供本仓库的页结构和编码测试，不提供浏览器持久化 API。

## 用法

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
  again.close()
}
```

`open`、`begin`、`get`、`put`、`delete`、`commit`、`abort`、`close` 都是 `async`，失败抛 `DbError`。

本仓库执行 `moon run src/cmd/main --target native --release`，会在当前目录生成 `vellum-example.db` 和 `.wal`，关掉再打开，打印 `b"vellum"`。父目录必须已经存在；只调用 `open/close` 或提交只读事务不会创建新库文件。

## 事务

一个 `Db` 同时只能有一个 `Txn`。上一个还没 `commit` 或 `abort` 就再 `begin`，得到 `DbError::TxnOpen`。

没提交的写入，换一次 `open` 就看不到。`abort` 回到上次提交的内容。`close` 时事务还开着，这次写入直接丢掉。

`put`、`delete` 失败不会留下部分修改；事务中此前成功的操作仍然保留，可以继续操作或 `abort`。事务只记录改过的页及其原值，`begin` 不复制整个页表，`abort` 只恢复这次修改过的页。

`commit` 或 `abort` 成功后，事务句柄失效；继续使用抛 `DbError::TxnClosed`。提交正在进行时，同一事务的读写、撤销和 `Db::close` 抛 `DbError::TxnBusy`，不能与提交并发执行。

`commit` 先把脏页和提交记录写入 `路径.wal` 并同步，再按偏移写入主文件的脏页，最后同步主文件、清空并同步 WAL。不截断主文件，不重写未修改的页。没有实际修改的事务提交不做磁盘 I/O。

下次 `open` 先把完整已提交 WAL 覆盖到对应页，再验证页文件和树结构。不完整的已知帧尾部丢弃；完整帧损坏抛 `Corrupt`，日志保留。日志不能补回未记录的缺失页，不能修复旧版全量截断导致的任意数据丢失。

`commit` 的磁盘操作失败后，原调用抛 `Io`，句柄进入 `RecoveryRequired`；只能 `close` 后重新 `open`。不要 `abort` 或盲目重试提交：WAL 可能已经提交，重新打开才能确定结果。

错误处理按 `DbError` 分支，不要吞掉提交错误。使用 `defer db.close()` 保证退出时释放事务；操作失败后可以撤销，但提交失败后应关闭并重开再查验最终值。取消提交也会让句柄进入 `RecoveryRequired`，未提交的日志不会重放。

## 边界

页长 `page_size`，固定 4096 字节。单个 value 不超过 `max_value_len`（4000）字节，且 `key.length() + value.length() <= 4085`。键和值不能跨页；分支分隔键也必须能编码进页。容量不满足时抛 `ValueTooLarge`，原数据保留。

版本 1 的键排序是 shortlex：先比较字节长度，长度相同再按字节比较。例如 `b"z"` 在 `b"aa"` 之前。这次优化不改变磁盘格式和排序。

`get` 直接扫描编码页的视图，只复制命中的 value，不解码和复制叶内全部 value。修改路径的页内查找使用二分搜索。

一个路径只允许一个打开的写入句柄，包括同一进程里的多个 `Db`。没有文件锁，同时写入同一路径会把文件写坏。

`open` 把整个库载入内存并验证可达节点、排序、叶链和 freelist，不是按需读盘的页缓存。内存占用随库大小增长；删除后的页会复用，但不会缩小文件。

恢复保证针对进程中断以及日志记录页的部分写入。主文件和 WAL 都显式同步，但没有同步首次创建的父目录项，尚未验证整机掉电耐久性。数据节点页没有 CRC，value 的位翻转不一定能检出；格式 1 也没有事务级页数或摘要，不能保证检出按完整帧边界丢失的日志。需要更强保障时应先设计新格式，而不是把它当作现有保证。

## 错误

| 错误 | 何时出现 |
| --- | --- |
| `Closed` | `close` 之后还用这个 `Db` 或它的 `Txn` |
| `TxnOpen` | 前一个事务没结束就 `begin` |
| `TxnClosed` | 继续使用已提交或已撤销的事务 |
| `TxnBusy` | 提交过程中对同一事务操作或关闭库 |
| `RecoveryRequired` | 提交 I/O 失败后继续操作；需要关闭并重新打开 |
| `ValueTooLarge` | value 超过 4000 字节，或这一页放不下 |
| `Corrupt` | 页文件头、页结构或完整 WAL 帧损坏；数据页本身没有 CRC |
| `Io(String)` | 读写失败。字符串是底层错误 |

## 性能基准

```sh
moon run src/cmd/bench --target native --release
```

基准使用临时目录，结束后删除文件。分别填入 32、128、512 个键，每个 value 3000 字节；每种规模输出三次采样：200 次 `begin/get/abort`、3 次同值提交、4 次交替值提交，以及建库和重新打开耗时。重新打开后逐键核对数据。

本机 native release、同一份基准的测量范围（毫秒）：

| 512 键，约 2 MiB | 优化前 | 优化后 |
| --- | ---: | ---: |
| 200 次读事务 | 10 | 1 |
| 3 次同值提交 | 75–80 | 0 |
| 4 次单键更新提交 | 104–108 | 2–3 |

时钟分辨率是毫秒，`0` 表示未跨过一个计时刻度，不是零成本。这些数字来自 Linux/WSL 的一次三采样运行，不是吞吐承诺；文件系统、缓存和同步延迟会改变结果。首次建库成本仍随数据量增长，`open` 仍需载入并验证整个库。

## 开发验证

```sh
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon test --target wasm-gc -p Nanaloveyuki/vellum
moon run src/cmd/main --target native --release
```

native 测试包含固定种子的 Map 模型对照、真正跨页的分裂/删除/重用、失效事务和 WAL 故障场景。纯页结构与编码测试也在 wasm-gc 运行。测试故障注入不等于真实掉电验证。

已运行独立写入进程：WAL 同步后将主文件尾部截短一个字节，发送 SIGKILL，再由新进程恢复、核对未修改页和新值、提交第三笔事务并重开。该场景通过；它验证进程中断恢复，不验证掉电或硬件缓存丢失。

## 许可证

Apache-2.0。
