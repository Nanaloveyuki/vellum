///|
priv enum LegacyNode {
  LegacyLeaf(keys~ : Array[BytesView], right~ : Int32)
  LegacyBranch(keys~ : Array[BytesView], children~ : Array[Int32])
  LegacyFree(next~ : Int32)
}

///|
fn legacy_compare(left : BytesView, right : BytesView) -> Int32 {
  if left.length() != right.length() {
    return left.length() - right.length()
  }
  for i in 0..<left.length() {
    let difference = left[i].to_int() - right[i].to_int()
    if difference != 0 {
      return difference
    }
  }
  0
}

///|
fn legacy_decode_leaf(page : Bytes) -> (Array[BytesView], Int32) raise DbError {
  guard page.length() == page_size && page[0] == kind_leaf else {
    raise DbError::Corrupt
  }
  let count = read_u16(page, 1)
  let right = read_u32(page, 3).reinterpret_as_int()
  guard right >= 0 else { raise DbError::Corrupt }
  let keys : Array[BytesView] = []
  let mut cursor = 7
  for _ in 0..<count {
    guard cursor + 4 <= page_size else { raise DbError::Corrupt }
    let key_len = read_u16(page, cursor)
    let value_len = read_u16(page, cursor + 2)
    guard value_len <= max_value_len &&
      cursor + 4 + key_len + value_len <= page_size else {
      raise DbError::Corrupt
    }
    let key = page[cursor + 4:cursor + 4 + key_len]
    if keys.last() is Some(previous) && legacy_compare(previous, key) >= 0 {
      raise DbError::Corrupt
    }
    keys.push(key)
    cursor = cursor + 4 + key_len + value_len
  }
  (keys, right)
}

///|
fn legacy_decode_branch(
  page : Bytes,
) -> (Array[BytesView], Array[Int32]) raise DbError {
  guard page.length() == page_size && page[0] == kind_branch else {
    raise DbError::Corrupt
  }
  let key_count = read_u16(page, 1)
  let children = []
  let mut cursor = 3
  for _ in 0..<(key_count + 1) {
    guard cursor + 4 <= page_size else { raise DbError::Corrupt }
    let child = read_u32(page, cursor).reinterpret_as_int()
    guard child > 0 else { raise DbError::Corrupt }
    children.push(child)
    cursor = cursor + 4
  }
  let keys = []
  for _ in 0..<key_count {
    guard cursor + 2 <= page_size else { raise DbError::Corrupt }
    let key_len = read_u16(page, cursor)
    guard cursor + 2 + key_len <= page_size else { raise DbError::Corrupt }
    let key = page[cursor + 2:cursor + 2 + key_len]
    if keys.last() is Some(previous) && legacy_compare(previous, key) >= 0 {
      raise DbError::Corrupt
    }
    keys.push(key)
    cursor = cursor + 2 + key_len
  }
  (keys, children)
}

///|
fn legacy_decode_node(page : Bytes) -> LegacyNode raise DbError {
  guard page.length() == page_size else { raise DbError::Corrupt }
  match page[0] {
    b'\x01' => {
      let (keys, right) = legacy_decode_leaf(page)
      LegacyLeaf(keys~, right~)
    }
    b'\x02' => {
      let (keys, children) = legacy_decode_branch(page)
      LegacyBranch(keys~, children~)
    }
    b'\x03' => LegacyFree(next=decode_free(page))
    _ => raise DbError::Corrupt
  }
}

///|
fn legacy_decode_header(page : Bytes) -> Meta raise DbError {
  guard page.length() == page_size else { raise DbError::Corrupt }
  guard page[0:8] == magic[:] && read_u32(page, 8) == 1U else {
    raise DbError::Corrupt
  }
  guard read_u32(page, 12) == page_size.reinterpret_as_uint() else {
    raise DbError::Corrupt
  }
  guard crc32(page[:header_len]) == read_u32(page, header_len) else {
    raise DbError::Corrupt
  }
  {
    root: read_u64_as_int(page, 16),
    freelist: read_u64_as_int(page, 24),
    txn_id: read_u64_as_int(page, 32),
    page_count: read_u64_as_int(page, 40),
  }
}

///|
fn legacy_read_image(
  bytes : Bytes,
  replayed : Map[Int32, Bytes],
) -> (Meta, Map[Int32, Bytes]) raise DbError {
  let header = match replayed.get(0) {
    Some(page) => page
    None if bytes.length() >= page_size => bytes[:page_size].to_owned()
    None => raise DbError::Corrupt
  }
  let meta = legacy_decode_header(header)
  guard meta.page_count >= 1 &&
    meta.page_count <= 0x7FFFFFFF / page_size &&
    meta.root >= 0 &&
    meta.root < meta.page_count &&
    meta.freelist >= 0 &&
    meta.freelist < meta.page_count else {
    raise DbError::Corrupt
  }
  let expected = meta.page_count * page_size
  guard bytes.length() <= expected else { raise DbError::Corrupt }
  if replayed.is_empty() {
    guard bytes.length() == expected else { raise DbError::Corrupt }
  } else {
    guard replayed.contains(0) else { raise DbError::Corrupt }
  }
  for id, page in replayed {
    guard id >= 0 && id < meta.page_count && page.length() == page_size else {
      raise DbError::Corrupt
    }
  }
  let pages : Map[Int32, Bytes] = Map([])
  pages[0] = header
  for id in 1..<meta.page_count {
    let page = match replayed.get(id) {
      Some(page) => page
      None => {
        guard (id + 1) * page_size <= bytes.length() else {
          raise DbError::Corrupt
        }
        bytes[id * page_size:(id + 1) * page_size].to_owned()
      }
    }
    pages[id] = page
  }
  let visited : Map[Int32, Bool] = Map([])
  let leaves : Array[(Int32, Int32)] = []
  let stack : Array[(Int32, BytesView?, BytesView?)] = []
  if meta.root != 0 {
    stack.push((meta.root, None, None))
  }
  while stack.pop() is Some((id, lower, upper)) {
    guard id > 0 && id < meta.page_count && !visited.contains(id) else {
      raise DbError::Corrupt
    }
    visited[id] = true
    let page = pages[id]
    match legacy_decode_node(page) {
      LegacyLeaf(keys~, right~) => {
        for key in keys {
          if lower is Some(bound) && legacy_compare(key, bound) < 0 {
            raise DbError::Corrupt
          }
          if upper is Some(bound) && legacy_compare(key, bound) >= 0 {
            raise DbError::Corrupt
          }
        }
        guard right >= 0 && right < meta.page_count else {
          raise DbError::Corrupt
        }
        leaves.push((id, right))
      }
      LegacyBranch(keys~, children~) => {
        for key in keys {
          if lower is Some(bound) && legacy_compare(key, bound) < 0 {
            raise DbError::Corrupt
          }
          if upper is Some(bound) && legacy_compare(key, bound) >= 0 {
            raise DbError::Corrupt
          }
        }
        for i = children.length() - 1; i >= 0; i = i - 1 {
          let child_lower = if i == 0 { lower } else { Some(keys[i - 1]) }
          let child_upper = if i == keys.length() {
            upper
          } else {
            Some(keys[i])
          }
          stack.push((children[i], child_lower, child_upper))
        }
      }
      LegacyFree(..) => raise DbError::Corrupt
    }
  }
  for i in 0..<leaves.length() {
    let (_, right) = leaves[i]
    let expected_right = if i + 1 < leaves.length() {
      leaves[i + 1].0
    } else {
      0
    }
    guard right == expected_right else { raise DbError::Corrupt }
  }
  let mut id = meta.freelist
  while id != 0 {
    guard id > 0 && id < meta.page_count && !visited.contains(id) else {
      raise DbError::Corrupt
    }
    visited[id] = true
    id = match legacy_decode_node(pages[id]) {
      LegacyFree(next~) => next
      _ => raise DbError::Corrupt
    }
  }
  for id in 1..<meta.page_count {
    guard visited.contains(id) else { raise DbError::Corrupt }
  }
  (meta, pages)
}
