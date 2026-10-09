///|
priv struct PageIndex {
  page : Bytes
  offsets : FixedArray[Int]
}

///|
// Entries are bound to immutable page identity, including replacements and rollback.
fn Tree::page_index(
  self : Tree,
  id : Int,
  page : Bytes,
) -> PageIndex raise DbError {
  if self.lookup_cache.get(id) is Some(index) &&
    physical_equal(index.page, page) {
    return index
  }
  let index = index_page(page)
  if !self.lookup_cache.contains(id) {
    let old = self.lookup_slots[self.lookup_next]
    self.lookup_cache.remove(old)
    self.lookup_slots[self.lookup_next] = id
    self.lookup_next = (self.lookup_next + 1) % self.lookup_slots.length()
  }
  self.lookup_cache[id] = index
  index
}

///|
fn index_page(page : Bytes) -> PageIndex raise DbError {
  guard page.length() == page_size else { raise DbError::Corrupt }
  let leaf = page[0] == kind_leaf
  guard leaf || page[0] == kind_branch else { raise DbError::Corrupt }
  let count = read_u16(page, 1)
  guard count <= (page_size - 7) / 4 else { raise DbError::Corrupt }
  let offsets = FixedArray::make(count, 0)
  let mut cursor = if leaf { 7 } else { 3 + (count + 1) * 4 }
  let mut previous : BytesView? = None
  if leaf {
    guard read_u32(page, 3).reinterpret_as_int() >= 0 else {
      raise DbError::Corrupt
    }
  } else {
    for i in 0..<=count {
      guard read_u32(page, 3 + i * 4).reinterpret_as_int() > 0 else {
        raise DbError::Corrupt
      }
    }
  }
  for i in 0..<count {
    let header = if leaf { 4 } else { 2 }
    guard cursor + header <= page_size else { raise DbError::Corrupt }
    let key_len = read_u16(page, cursor)
    let value_len = if leaf { read_u16(page, cursor + 2) } else { 0 }
    guard value_len <= max_value_len &&
      cursor + header + key_len + value_len <= page_size else {
      raise DbError::Corrupt
    }
    let key = page[cursor + header:cursor + header + key_len]
    if previous is Some(last) && last.compare(key) >= 0 {
      raise DbError::Corrupt
    }
    previous = Some(key)
    offsets[i] = cursor
    cursor += header + key_len + value_len
  }
  { page, offsets, }
}

///|
// Shortlex lower bound on already validated positions; branch equality routes right.
fn index_position(
  index : PageIndex,
  key : Bytes,
  branch~ : Bool,
) -> Int raise DbError {
  let mut low = 0
  let mut high = index.offsets.length()
  while low < high {
    let mid = low + (high - low) / 2
    let offset = index.offsets[mid]
    let length = read_u16(index.page, offset)
    let start = offset + (if branch { 2 } else { 4 })
    let order = index.page[start:start + length].compare(key[:])
    if order < 0 || (branch && order == 0) {
      low = mid + 1
    } else {
      high = mid
    }
  }
  low
}

///|
fn lookup_leaf(index : PageIndex, key : Bytes) -> Bytes? raise DbError {
  let position = index_position(index, key, branch=false)
  guard position < index.offsets.length() else { return None }
  let offset = index.offsets[position]
  let key_len = read_u16(index.page, offset)
  let start = offset + 4
  guard index.page[start:start + key_len] == key[:] else { return None }
  let value_len = read_u16(index.page, offset + 2)
  Some(index.page[start + key_len:start + key_len + value_len].to_owned())
}

///|
fn lookup_child(index : PageIndex, key : Bytes) -> Int raise DbError {
  let child = index_position(index, key, branch=true)
  read_u32(index.page, 3 + child * 4).reinterpret_as_int()
}

///|
fn append_leaf_keys(page : Bytes, keys : Array[Bytes]) -> Unit raise DbError {
  guard page.length() == page_size && page[0] == kind_leaf else {
    raise DbError::Corrupt
  }
  let mut cursor = 7
  for _ in 0..<read_u16(page, 1) {
    guard cursor + 4 <= page_size else { raise DbError::Corrupt }
    let key_len = read_u16(page, cursor)
    let value_len = read_u16(page, cursor + 2)
    guard cursor + 4 + key_len + value_len <= page_size else {
      raise DbError::Corrupt
    }
    let key = page[cursor + 4:cursor + 4 + key_len].to_owned()
    if keys.last() is Some(previous) && previous.compare(key) >= 0 {
      raise DbError::Corrupt
    }
    keys.push(key)
    cursor = cursor + 4 + key_len + value_len
  }
}
