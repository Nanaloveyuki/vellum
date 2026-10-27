---
status: accepted
---

# 事务内只读前向游标，写尝试即失效

用户确认在现有可变 `Txn` 中提供事务限定的前向只读游标：创建时可见该事务此前的写入；不提供 MVCC，也不允许同一游标边扫描边修改。为避免游标依赖最终逻辑相等、回滚后页对象或拓扑是否恢复，任何 `put/delete` 尝试在活动事务的 `require_txn` 成功后，都使已有游标失效，包括同值覆盖、删除不存在的键、`ValueTooLarge` 及触页失败后的操作回滚；状态检查已拒绝的调用不算被活动事务接受的尝试。[现有事务检查](../../src/db.mbt#L90-L144)、[容量检查](../../src/tree.mbt#L232-L257)

`commit/abort/close` 使游标失效，耗尽也不能绕过生命周期检查；这是保守地放弃无变化或失败写入后续扫的便利，而不是快照或每行重新定位。[现有结束生命周期](../../src/db.mbt#L153-L243)

用户确认 async `Txn.scan(start : Bytes, end? : Bytes)`、`Txn.scan_prefix(prefix : Bytes)` 返回 `Cursor`，async `Cursor.next()` 返回独立拥有的可选键值对，均抛 `DbError`；从下界定位一次后增量沿叶链，不全库枚举/排序、逐行重新下降或增加反向/分页/重复 interface。范围 `[start,end)` 可无上界，逆序报无载荷 `InvalidRange`，相等为空；空前缀全库，全 0xff 前缀无有限上界，其余取最短字节后继作为排除上界。检查优先级为 `Closed`、`RecoveryRequired`、事务 `TxnBusy/TxnClosed`、无载荷 `CursorInvalidated`，最后行或 EOF；scan 参数检查也在事务状态后，有效 EOF 重复 `None`。[现有状态优先级](../../src/db.mbt#L84-L98)

仓库 0.4.0 已实现于 [cursor.mbt](../../src/cursor.mbt)，随 0.4.1 发布到 Mooncakes。同一代游标共享惰性创建的有效性令牌；写尝试只将令牌失效，下一代首次扫描才分配新令牌，不依赖会回绕的计数器。native 回归通过 public seam 检查二进制范围、前缀、跨页、失效和行所有权；必要白盒安排覆盖空叶、提交忙态、真实 I/O 失败与取消。
