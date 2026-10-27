///|
priv struct CursorValidity {
  mut valid : Bool
}

///|
/// 当前事务的只读前向游标；任何被接受的写尝试都使它失效。
pub struct Cursor {
  priv txn : Txn
  priv validity : CursorValidity
  priv end : Bytes?
  priv mut index : PageIndex?
  priv mut slot : Int32
  priv mut remaining : Int32
}

///|
fn Txn::invalidate_cursors(self : Txn) -> Unit {
  if self.cursor_validity is Some(validity) {
    validity.valid = false
  }
}

///|
fn Txn::cursor_generation(self : Txn) -> CursorValidity {
  if self.cursor_validity is Some(validity) && validity.valid {
    validity
  } else {
    let validity = { valid: true, }
    self.cursor_validity = Some(validity)
    validity
  }
}

///|
fn Tree::seek_cursor(
  self : Tree,
  start : Bytes,
) -> (PageIndex, Int32)? raise DbError {
  let mut id = self.root
  let mut remaining = self.next_page
  while id != 0 {
    guard id > 0 && id < self.next_page && remaining > 0 else {
      raise DbError::Corrupt
    }
    remaining -= 1
    let page = match self.pages.get(id) {
      Some(page) => page
      None => raise DbError::Corrupt
    }
    guard page.length() == page_size else { raise DbError::Corrupt }
    let index = self.page_index(id, page)
    if page[0] == kind_leaf {
      return Some((index, index_position(index, start[:], branch=false)))
    }
    guard page[0] == kind_branch else { raise DbError::Corrupt }
    id = lookup_child(index, start)
  }
  None
}

///|
#warnings("-unused_async")
/// 遍历字节字典序的半开区间 `[start, end)`；省略 end 表示无上界。
pub async fn Txn::scan(
  self : Txn,
  start : Bytes,
  end? : Bytes,
) -> Cursor raise DbError {
  require_txn(self)
  let empty = match end {
    Some(bound) => {
      let order = compare_bytes(start, bound)
      guard order <= 0 else { raise DbError::InvalidRange }
      order == 0
    }
    None => false
  }
  let position = if empty { None } else { self.db.tree.seek_cursor(start) }
  let (index, slot) = match position {
    Some((index, slot)) => (Some(index), slot)
    None => (None, 0)
  }
  {
    txn: self,
    validity: self.cursor_generation(),
    end,
    index,
    slot,
    remaining: self.db.tree.next_page,
  }
}

///|
/// 遍历具有任意二进制前缀的键；空前缀遍历全部键。
pub async fn Txn::scan_prefix(
  self : Txn,
  prefix : Bytes,
) -> Cursor raise DbError {
  require_txn(self)
  let mut length = prefix.length()
  while length > 0 && prefix[length - 1] == b'\xff' {
    length -= 1
  }
  if length == 0 {
    self.scan(prefix)
  } else {
    let upper = Bytes::makei(length, i => {
      if i == length - 1 {
        (prefix[i].to_int() + 1).to_byte()
      } else {
        prefix[i]
      }
    })
    self.scan(prefix, end=upper)
  }
}

///|
#warnings("-unused_async")
/// 返回独立拥有的键值行；有效耗尽后重复返回 None，仍检查事务状态和失效。
pub async fn Cursor::next(self : Cursor) -> (Bytes, Bytes)? raise DbError {
  require_txn(self.txn)
  guard self.validity.valid else { raise DbError::CursorInvalidated }
  while self.index is Some(index) {
    if self.slot < index.offsets.length() {
      let offset = index.offsets[self.slot]
      let key_len = read_u16(index.page, offset)
      let value_len = read_u16(index.page, offset + 2)
      let start = offset + 4
      let key = index.page[start:start + key_len]
      if self.end is Some(end) && compare_bytes_view(key, end[:]) >= 0 {
        self.index = None
        return None
      }
      self.slot += 1
      return Some(
        (
          key.to_owned(),
          index.page[start + key_len:start + key_len + value_len].to_owned(),
        ),
      )
    }
    let id = read_u32(index.page, 3).reinterpret_as_int()
    if id == 0 {
      self.index = None
      return None
    }
    let tree = self.txn.db.tree
    guard id > 0 && id < tree.next_page && self.remaining > 0 else {
      raise DbError::Corrupt
    }
    self.remaining -= 1
    let page = match tree.pages.get(id) {
      Some(page) => page
      None => raise DbError::Corrupt
    }
    guard page.length() == page_size && page[0] == kind_leaf else {
      raise DbError::Corrupt
    }
    self.index = Some(tree.page_index(id, page))
    self.slot = 0
  }
  None
}
