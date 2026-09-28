# vellum

纯 MoonBit 嵌入式页存储。单文件、单写者、崩溃可恢复。

别的 MoonBit 程序要在进程退出后还留下数据，又不想链 SQLite 或外部数据库。调用面是 `open`、`begin`、`get`、`put`、`delete`、`commit`、`abort`、`close`。这些函数都是 `async`。

文件 IO 走 `moonbitlang/async`。不写 C FFI，不依赖 orbit。

## 安装

`moon.mod`：

```
import {
  "Nanaloveyuki/vellum",
}
```

## 最小示例

```mbt nocheck
async fn main {
  let db = @vellum.open("notes.db")
  let txn = db.begin()
  txn.put(b"hello", b"vellum")
  txn.commit()
  db.close()

  let again = @vellum.open("notes.db")
  let read = again.begin()
  let _ = read.get(b"hello")
  read.abort()
  again.close()
}
```

`moon run src/cmd/main` 会在当前目录写下 `vellum-example.db`，关闭后再打开，读回 `b"vellum"`。

未 `commit` 的写入，`get` 在别的打开里看不见。`abort` 和未提交的 `close` 丢掉当前事务。同一时刻只能有一个 `Txn`。

## 崩溃恢复

页大小固定 4096 字节。`commit` 先把脏页和提交帧写进 `path.wal` 并同步，再刷进页文件，最后清空 WAL。

下次 `open` 只重放校验完整、且属于已提交事务的帧。尾部半帧丢掉。页文件已经刷完之后，WAL 被清空，不再重放。

第一版不做：SQL、网络、多进程锁、MVCC、压缩、加密、跨页 value。超过单页上限返回 `DbError::ValueTooLarge`。wasm 后端只覆盖内存里的页和 B+ 树，不承诺浏览器持久化。

## 许可证

Apache-2.0。
