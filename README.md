# vellum

vellum 是用 MoonBit 编写的嵌入式键值存储，直接在应用进程里运行。键和值都是 `Bytes`，数据保存在本地页文件中，旁边的 WAL 用于进程中断后的恢复。没有 SQL，也不需要数据库服务。

适合能整体放进内存、由单个句柄管理的本地数据，例如应用设置、工具状态或小型索引。当前磁盘 API 只支持 `native`。

- 用 `get`、`put`、`delete` 读写数据。
- 一次事务可以修改多个键，最后统一 `commit`，或用 `abort` 撤销。
- 重新打开时自动恢复完整已提交的 WAL，并检查页结构。

## 快速开始（已发布的 0.3.0）

已发布的 0.3.0 仍使用 v1 shortlex；下文依赖示例对应该发布版。当前仓库版本为 0.4.0，使用 v2，尚未发布到 Mooncakes；范围/前缀游标、元数据示例和显式迁移等后续章节描述的是仓库 0.4.0，而非下文安装的 0.3.0。

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

常见错误还有 `Closed`、`TxnOpen`、`TxnClosed`、`ValueTooLarge`、`UnsupportedFormat`、`Corrupt` 和 `Io(String)`。`get` 在键不存在时返回 `None`，`delete` 返回是否删除了已有键。

## 范围与前缀扫描

以下是仓库 0.4.0 的 API，不包含在已发布的 0.3.0 中。

`Txn.scan(start, end=...)` 按字节字典序遍历 `[start,end)`，省略 `end` 表示无上界；相等边界是空范围，逆序边界报 `InvalidRange`。`Txn.scan_prefix(prefix)` 返回同一种 `Cursor`：空前缀扫描全部键，全 `0xff` 前缀也可使用。

```mbt nocheck
let txn = db.begin()
let cursor = txn.scan_prefix(b"notes/")
while cursor.next() is Some((key, value)) {
  println("\{key}: \{value}")
}
txn.abort()
```

游标看见创建前该事务的写入，只定位一次下界，之后沿叶链增量读取。每行键值独立拥有，有效耗尽后重复返回 `None`。它不是快照：活动事务接受的任何 `put/delete` 尝试都会使已有游标报 `CursorInvalidated`，包括同值覆盖、删除缺失键、容量错误和操作失败回滚；之后可创建新游标观察保留的数据。先完成只读遍历再修改，不在同一游标上边扫边写。

即使已经耗尽，`next` 仍依次检查 `Closed`、`RecoveryRequired`、`TxnBusy/TxnClosed`，然后才检查失效和 EOF；`commit/abort/close` 不留下可继续遍历的句柄。`scan` 也先检查事务状态，再检查边界。

## 调用者文件元数据示例

仓库 0.4.0 的 `src/cmd/metadata` 只通过 public 事务和游标维护本地主记录及记录目录、记录修改时间两个二级索引：

```sh
moon run src/cmd/metadata --target native
```

示例输入是合成的 `path/size/mtime`，不读取文件内容、OS stat 或自动采样时间，也不扫描、监听真实文件系统。记录路径就是区分大小写的身份；改名在一个事务中删除旧身份并插入新身份，不提供稳定文件 ID。路径必须已规范、相对且以 `/` 分隔，拒绝空路径、绝对/盘符形式、NUL、反斜杠、重复或尾部分隔符及 `.`/`..` 段，不暗中折叠；`notes:a` 这样的非盘符冒号可用。不保证 Unicode 归一、符号链接解析或跨 OS 路径语义。

空目录查询表示根，其余目录遵守相同路径规则；只查询直接子项。时间是调用者提供的有符号 Int64 UTC Unix epoch 毫秒，按数值排序，同时间按 UTF-8 路径字节序。主记录、目录和时间键分别使用独立命名域；目录用禁止出现在路径中的 NUL 分隔字段，时间使用翻转符号位的大端编码。

可执行程序实际运行 upsert、清理旧索引、missing delete、成功/缺失/冲突/同路径改名、输入拒绝和容量失败撤销；关闭重开后检查全部主记录和两个索引，包括负/零/正时间、Int64 极值及时间平局。一次逻辑更新中的任何维护错误都会撤销整个事务。提交 I/O 错误或取消仍遵守库的 `RecoveryRequired` 契约，不能据此断言没有写入或自动重试，须关闭重开确认。

## 显式迁移 v1

仓库 0.4.0 提供 `@vellum.migrate_v1(source, destination)`，不需要先调用 `open` 或扫描。停用源库、确保单所有者及路径稳定，并准备一个已有的目标父目录：

```mbt nocheck
@vellum.migrate_v1("old.db", "converted.db")
let converted = @vellum.open("converted.db")
```

迁移全程只读源主文件和 WAL，先在内存覆盖有效已提交 redo，再按旧 shortlex 严格验证；完整 WAL 能恢复的缺失或撕裂主文件也可迁移。缺失/零字节且无有效 v1 头不算空旧库，合法空库则生成持久 v2 头。拒绝源主文件/WAL 的叶子符号链接；源硬链接不会被写入。解析父目录后源/目标不能重叠，目标主文件和 `.wal` 不能有任何已有目录项，包括悬空链接。

数据在目标同目录的独占 staging 中重建；全部键值字节、条数和 v2 图结构均核对，主文件和空 staging WAL 同步后，再以 native 不覆盖 rename 发布完整主文件。正常返回时目标可重开，最终 `.wal` 不存在；不支持该发布 primitive 的平台/文件系统会失败，不降级覆盖。

**只有正常返回才表示完成。** I/O 错误或取消不会写源，也不会自动重试、切换源路径或删除最终目标；可能残留 staging 或已发布的完整目标。检查并人工清理残留，确认数据后由调用者显式切换路径，不能仅凭目标存在认定成功。不承诺路径竞态攻击安全、双文件原子发布或整机掉电耐久性。

## 使用前须知

- **同一路径只打开一个 `Db`。** 没有文件锁，同一进程或不同进程同时写入会损坏数据；没有并行读快照。
- `open` 会把整个库载入内存并验证结构，内存占用随库大小增长。删除后的空间会复用，但文件不会缩小。
- 固定 4096 字节页。单个 value 最多 4000 字节，且 `key.length() + value.length() <= 4085`；键和值不能跨页，分支分隔键也必须能放进页。超限抛 `ValueTooLarge`。
- 仓库 0.4.0 的格式 v2 使用无符号字节字典序：首个不同字节决定大小，相同前缀的短键在前，例如 `b"aa"` 在 `b"z"` 之前。空键、空值及任意二进制键均可使用；`get` 返回独立拥有的值。
- 仓库 0.4.0 的普通 `open` 仅接受 v2，不自动升级。有效 v1 shortlex 库报无载荷 `UnsupportedFormat`；先只读覆盖已提交 WAL 再验证，拒绝时不回写主文件、不创建或清空源 WAL。坏头、节点、图或完整 WAL 帧仍报 `Corrupt`。显式迁移见上节。
- 主文件与 WAL 都显式同步。恢复覆盖进程中断及日志记录页的部分写入，不能补回日志中没有的缺失页。首次创建的父目录项未同步，尚未验证整机掉电耐久性。
- 数据页没有 CRC，value 的位翻转不一定能检出；WAL 完整帧损坏会报 `Corrupt`，但 v2 沿用原有日志结构，没有事务级页数或摘要，不能保证检出按完整帧边界丢失的日志。恢复不是备份。

`async` 签名不代表每次操作都会让出调度。长循环可在完整操作之间调用 `@async.pause()`，例如每 128 次写入后让其他任务运行；间隔应按实际负载测量。

## 0.4.0

当前仓库版本为 0.4.0，尚未发布到 Mooncakes。

使用 v2 字节字典序格式，新增事务内前向范围/前缀游标、只读显式 v1 迁移、调用者文件元数据示例和固定结果扫描规模对照。与 0.2.0/0.3.0 的 v1 shortlex 不直接读写兼容：普通 `open` 对有效 v1 报 `UnsupportedFormat`，须显式调用 `migrate_v1` 在不同路径重建，再由调用者切换路径；源主文件和 WAL 全程只读。

native 运行核对了混合二进制键事务、redo 恢复及真实 0.3.0 多页旧库迁移：无 WAL、已提交 WAL、撕裂/缺失主文件及合法空库都经逐行字节核对；源 main/WAL 保留、目标占用和链接拒绝、staging 期间取消也已实际运行。

## 0.3.0

0.3.0 发布版本优化了 CRC、页内查找、节点复用和批量脏页写入；当时的公开 API、错误分支、版本 1 磁盘格式与 shortlex 排序不变，并验证了与 0.2.0 双向读写兼容。此历史兼容性不适用于仓库 0.4.0 的 v2 格式。

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

## 固定结果的扫描规模对照

仓库 0.4.0 可运行独立 native release 基准：

```sh
moon run src/cmd/scan_bench --target native --release
```

每个规模固定查询同一段 100 个 ASCII 键，保持相同键和值，在范围前后增加无关键，总量依次为 1,000、10,000 和 100,000。范围游标的计时包含创建及消费全部 owned 行；对照明确为 **全量 public cursor 枚举 owned 键值行、独立无符号字节排序、再过滤同一区间**，不是点查，也不是 MoonKV 的实现或测量。两条路径在计时外逐行核对数量、顺序和键值字节，整库数据也独立核对。

输出建库/提交/关闭及 full-image open 的独立耗时，并报告三次真实样本、重复次数、总毫秒和换算的每次平均微秒。毫秒分辨率允许零样本，不补造精度；运行时请同时记录 `moon version`、编译模式与 OS/架构。所有临时数据库结束后删除。

范围游标的成本包含下界树下降、访问的叶页以及返回行复制；全量枚举排序还处理无关行。库仍在 `open` 时加载并验证整份镜像，内存随总规模增长；本基准不改善或隐藏 open 成本。缓存、分配、文件系统和系统负载会影响样本，不设速度倍数、吞吐或延迟通过阈值，也不承诺同路径多进程安全。

## 开发

```sh
moon fmt --check
moon check --target native --deny-warn
moon test --target native
moon test src --target wasm-gc
```

磁盘测试在 native 运行；wasm-gc 只用于纯页结构与编码测试，不提供浏览器持久化 API。回归覆盖模型对照、跨页修改、撤销、页复用、缓存失效、I/O 故障与取消。

[CI 工作流](.github/workflows/ci.yml) 在 Ubuntu 上运行上述检查与 native/纯 wasm-gc 测试，再以 native release 执行 `src/cmd/main` 快速示例、`src/cmd/bench` 点查基准、`src/cmd/metadata` 元数据示例和 `src/cmd/scan_bench` 固定结果扫描对照。程序核对失败会使 CI 失败，但不设耗时或性能通过阈值；本地按该执行顺序已运行通过，不代表远程 GitHub CI 已运行或通过。

独立进程验证在 WAL 同步后、主文件部分写入后、主文件同步后分别 SIGKILL，再由 0.2.0 和 0.3.0 恢复。六个场景均核对全部 600 条记录，随后成功提交并重开；这不等于整机掉电验证。

## 许可证

[Apache-2.0](LICENSE)。
