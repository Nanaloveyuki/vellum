---
status: accepted
---

# 新格式 v2 使用字节字典序

新格式 v2 按无符号字节字典序排列键，使变长组合键的常规范围和前缀查询具有连续区间；不继续以长度优先的 shortlex 作为新格式排序。已有 v1 shortlex 不能仅替换比较器或改写文件头：进入 v2 必须重建有序树，普通 `open` 不得静默升级。[当前格式与约束](../../README.md#使用前须知)

**实现状态：仓库 0.4.0 的 v2 点查事务与恢复已实现并通过 native public smoke。** 普通打开先只读覆盖已提交 WAL，再严格验证有效头及完整图；有效 v1 报无载荷 `UnsupportedFormat`，坏头、节点、图或完整 WAL 帧报 `Corrupt`。真实 0.3.0 旧库在无 WAL、有 WAL 与可恢复撕裂主文件时均已核对拒绝且源字节不变。shortlex 解码及图校验隔离在只读 legacy reader，不进入 v2 writer；游标与显式迁移也已在仓库 0.4.0 实现、尚未发布到 Mooncakes，迁移/发布约束见 [ADR-0004](0004-read-only-legacy-migration.md)。
