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

磁盘读写只在 `native` 上。`wasm` 能跑内存里的页结构，不会帮你把文件存进浏览器。

## 用法

```mbt nocheck
async fn main {
  let db = @vellum.open("notes.db")
  let txn = db.begin()
  txn.put(b"hello", b"vellum")
  txn.commit()
  db.close()

  let again = @vellum.open("notes.db")
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

本仓库执行 `moon run src/cmd/main`，会在当前目录生成 `vellum-example.db`，关掉再打开，打印 `b"vellum"`。

## 事务

一个 `Db` 同时只能有一个 `Txn`。上一个还没 `commit` 或 `abort` 就再 `begin`，得到 `DbError::TxnOpen`。

没提交的写入，换一次 `open` 就看不到。`abort` 回到上次提交的内容。`close` 时事务还开着，这次写入直接丢掉。

`put`、`delete` 失败不会留下部分修改；事务中此前成功的操作仍然保留，可以继续操作或 `abort`。事务只记录改过的页及其原值，`begin` 不复制整个页表，`abort` 只恢复这次修改过的页。

`commit` 或 `abort` 成功后，事务句柄失效；继续使用抛 `DbError::TxnClosed`。提交正在进行时，同一事务的读写、撤销和 `Db::close` 抛 `DbError::TxnBusy`，不能与提交并发执行。

`commit` 先把脏页和提交记录写入 `路径.wal` 并同步，再按偏移写入主文件的脏页，最后同步主文件、清空并同步 WAL。不截断主文件，不重写未修改的页。没有实际修改的事务提交不做磁盘 I/O。

下次 `open` 先把完整已提交 WAL 覆盖到对应页，再验证页文件和树结构。不完整的已知帧尾部丢弃；完整帧损坏抛 `Corrupt`，日志保留。日志不能补回未记录的缺失页，不能修复旧版全量截断导致的任意数据丢失。

`commit` 的磁盘操作失败后，原调用抛 `Io`，句柄进入 `RecoveryRequired`；只能 `close` 后重新 `open`。不要 `abort` 或盲目重试提交：WAL 可能已经提交，重新打开才能确定结果。

## 边界

页长 `page_size`，固定 4096 字节。一个 value 最长 `max_value_len`（4000）字节，不能拆到下一页。超了，或者 key 长到当前页放不下，都是 `DbError::ValueTooLarge`。

版本 1 的键排序是 shortlex：先比较字节长度，长度相同再按字节比较。例如 `b"z"` 在 `b"aa"` 之前。这次优化不改变磁盘格式和排序。

`get` 直接扫描编码页的视图，只复制命中的 value，不解码和复制叶内全部 value。修改路径的页内查找使用二分搜索。

一个路径只允许一个打开的写入句柄，包括同一进程里的多个 `Db`。没有文件锁，同时写入同一路径会把文件写坏。

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

## 许可证

Apache-2.0。
