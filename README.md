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

`commit` 先把脏页和提交记录同步到 `路径.wal`，再写页文件，最后把 WAL 截成空文件。下次 `open` 只采纳完整且已提交的事务。不完整的已知帧尾部丢弃；完整帧的 CRC、字段或 kind 损坏抛 `Corrupt`，不静默舍弃后续日志。

## 边界

页长 `page_size`，固定 4096 字节。一个 value 最长 `max_value_len`（4000）字节，不能拆到下一页。超了，或者 key 长到当前页放不下，都是 `DbError::ValueTooLarge`。

比较顺序就是字节序。一个路径只给一个进程写。没有文件锁，两个进程一起写同一个路径会把文件写坏。

## 错误

| 错误 | 何时出现 |
| --- | --- |
| `Closed` | `close` 之后还用这个 `Db` 或它的 `Txn` |
| `TxnOpen` | 前一个事务没结束就 `begin` |
| `TxnClosed` | 继续使用已提交或已撤销的事务 |
| `TxnBusy` | 提交过程中对同一事务操作或关闭库 |
| `ValueTooLarge` | value 超过 4000 字节，或这一页放不下 |
| `Corrupt` | 页文件头、页结构或完整 WAL 帧损坏；数据页本身没有 CRC |
| `Io(String)` | 读写失败。字符串是底层错误 |

## 许可证

Apache-2.0。
