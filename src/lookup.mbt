///|
// Format v1 uses shortlex: compare lengths before lexical byte order.
fn lookup_leaf(page : Bytes, key : Bytes) -> Bytes? raise DbError {
  guard page.length() == page_size && page[0] == kind_leaf else {
    raise DbError::Corrupt
  }
  let count = read_u16(page, 1)
  let mut cursor = 7
  let mut previous : BytesView? = None
  let mut found : BytesView? = None
  for _ in 0..<count {
    guard cursor + 4 <= page_size else { raise DbError::Corrupt }
    let key_len = read_u16(page, cursor)
    let value_len = read_u16(page, cursor + 2)
    guard value_len <= max_value_len &&
      cursor + 4 + key_len + value_len <= page_size else {
      raise DbError::Corrupt
    }
    let stored_key = page[cursor + 4:cursor + 4 + key_len]
    if previous is Some(last) && last.compare(stored_key) >= 0 {
      raise DbError::Corrupt
    }
    previous = Some(stored_key)
    if stored_key == key[:] {
      found = Some(page[cursor + 4 + key_len:cursor + 4 + key_len + value_len])
    }
    cursor = cursor + 4 + key_len + value_len
  }
  found.map(view => view.to_owned())
}

///|
fn lookup_child(page : Bytes, key : Bytes) -> Int raise DbError {
  guard page.length() == page_size && page[0] == kind_branch else {
    raise DbError::Corrupt
  }
  let count = read_u16(page, 1)
  guard count <= (page_size - 7) / 4 else { raise DbError::Corrupt }
  let mut cursor = 3 + (count + 1) * 4
  let mut previous : BytesView? = None
  let mut child = 0
  for i in 0..<count {
    guard cursor + 2 <= page_size else { raise DbError::Corrupt }
    let len = read_u16(page, cursor)
    guard cursor + 2 + len <= page_size else { raise DbError::Corrupt }
    let separator = page[cursor + 2:cursor + 2 + len]
    if previous is Some(last) && last.compare(separator) >= 0 {
      raise DbError::Corrupt
    }
    previous = Some(separator)
    if key[:].compare(separator) >= 0 {
      child = i + 1
    }
    cursor = cursor + 2 + len
  }
  read_u32(page, 3 + child * 4).reinterpret_as_int()
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
