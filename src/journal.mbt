///|
/// 树级写入簿记。
///
/// - `undo`：自 `reset_changes` 以来每个改动页的原始字节。值是 `None` 表示这页
///   在事务开始时不存在（新分配的页）。事务撤销时用它恢复旧页，不需要整份 Map 拷贝。
/// - `op_undo` / `op_touched`：当前这次 `put`/`delete` 自己改过的页。
///   `op_touched` 记录这次操作碰过的每一页（即使该页更早的事务操作已经改过），
///   `op_undo` 记录每页在这次操作开始时的字节，失败时按它精确恢复。
/// - `op_added`：这次操作首次写进 `undo` 的页号。失败时只撤回这些新条目，
///   早先成功操作留下的 `undo` 原样保留，事务级回滚仍能回滚早先的改动。
/// - `op_root` / `op_freelist` / `op_next`：这次操作开始时的元数据。分配器推进
///   `next_page` 或改动 `root`/`freelist` 之后中途失败，要能一并还原。
fn Tree::begin_operation(self : Tree) -> Unit {
  self.op_root = self.root
  self.op_freelist = self.freelist
  self.op_next = self.next_page
}

///|
fn Tree::note_page(self : Tree, id : Int, previous : Bytes?) -> Unit {
  if self.op_touched.contains(id) {
    return
  }
  self.op_touched[id] = true
  self.op_undo[id] = previous
  if !self.undo.contains(id) {
    self.undo[id] = previous
    self.op_added[id] = true
  }
}

///|
/// 唯一写页入口。字节没有变化就什么都不做，也不记日志。
fn Tree::set_page(self : Tree, id : Int, page : Bytes) -> Unit {
  let previous = self.pages.get(id)
  if previous is Some(old) && old == page {
    return
  }
  self.note_page(id, previous)
  self.pages[id] = page
}

///|
/// 清空自事务开始以来的所有簿记。`begin` 时调用，事务提交后也调用。
fn Tree::reset_changes(self : Tree) -> Unit {
  self.undo.clear()
  self.op_undo.clear()
  self.op_touched.clear()
  self.op_added.clear()
}

///|
/// 回滚一次失败的 `put`/`delete`：把这次操作碰过的每一页恢复成这次操作开始时的
/// 字节，把 `root`/`freelist`/`next_page` 还原，并撤回这次操作首次写进 `undo` 的
/// 条目。早先成功操作的 `undo` 原样保留。
fn Tree::rollback_operation(self : Tree) -> Unit {
  for id, previous in self.op_undo {
    match previous {
      Some(page) => self.pages[id] = page
      None => self.pages.remove(id)
    }
  }
  for id, added in self.op_added {
    if added {
      self.undo.remove(id)
    }
  }
  self.root = self.op_root
  self.freelist = self.op_freelist
  self.next_page = self.op_next
  self.op_undo.clear()
  self.op_touched.clear()
  self.op_added.clear()
}

///|
/// 成功走完一次 `put`/`delete`：这次操作碰过的页从此归事务账本，不再单独回滚。
/// `undo` 里的条目（可能由这次操作首次写入）保持不动。
fn Tree::commit_operation(self : Tree) -> Unit {
  self.op_undo.clear()
  self.op_touched.clear()
  self.op_added.clear()
}

///|
/// 事务整份回滚：恢复所有改动页和 root/freelist/next_page，并清空簿记。
/// `abort` 用这个入口，不再整份拷贝 `pages`。
fn Tree::rollback_changes(
  self : Tree,
  root : Int,
  freelist : Int,
  next_page : Int,
) -> Unit {
  self.op_undo.clear()
  self.op_touched.clear()
  self.op_added.clear()
  for id, original in self.undo {
    match original {
      Some(page) => self.pages[id] = page
      None => self.pages.remove(id)
    }
  }
  self.undo.clear()
  self.root = root
  self.freelist = freelist
  self.next_page = next_page
}

///|
/// 事务实际改过的页号，升序。只报真的被写过的页，不报初始状态相同却没变的页。
fn Tree::changed_pages(self : Tree) -> Array[Int] {
  let ids = []
  for id, original in self.undo {
    match (original, self.pages.get(id)) {
      (Some(before), Some(after)) => if before != after { ids.push(id) }
      (None, Some(_)) => ids.push(id)
      (Some(_), None) => ids.push(id)
      (None, None) => ()
    }
  }
  ids.sort()
  ids
}
