///|
priv struct Entry {
  key : Bytes
  value : Bytes
}

///|
priv struct Leaf {
  entries : Array[Entry]
  right : Int
}

///|
priv struct Branch {
  keys : Array[Bytes]
  children : Array[Int]
}

///|
let kind_leaf : Byte = b'\x01'

///|
let kind_branch : Byte = b'\x02'

///|
let kind_free : Byte = b'\x03'

///|
priv enum Node {
  Leaf(Leaf)
  Branch(Branch)
  Free
}

///|
fn compare_bytes(left : Bytes, right : Bytes) -> Int {
  left.compare(right)
}

///|
fn encode_leaf(leaf : Leaf) -> FixedArray[Byte] raise DbError {
  let page = blank_page()
  page[0] = kind_leaf
  write_u16(page, 1, leaf.entries.length())
  write_u32(page, 3, leaf.right.reinterpret_as_uint())
  let mut cursor = 7
  for entry in leaf.entries {
    let need = 4 + entry.key.length() + entry.value.length()
    guard cursor + need <= page_size else { raise DbError::ValueTooLarge }
    write_u16(page, cursor, entry.key.length())
    write_u16(page, cursor + 2, entry.value.length())
    page.blit_from_bytes(cursor + 4, entry.key, 0, entry.key.length())
    page.blit_from_bytes(
      cursor + 4 + entry.key.length(),
      entry.value,
      0,
      entry.value.length(),
    )
    cursor = cursor + need
  }
  page
}

///|
fn decode_leaf(page : Bytes) -> Leaf raise DbError {
  guard page.length() == page_size && page[0] == kind_leaf else {
    raise DbError::Corrupt
  }
  let count = read_u16(page, 1)
  let right = read_u32(page, 3).reinterpret_as_int()
  guard right >= 0 else { raise DbError::Corrupt }
  let entries : Array[Entry] = []
  let mut cursor = 7
  for _ in 0..<count {
    guard cursor + 4 <= page_size else { raise DbError::Corrupt }
    let key_len = read_u16(page, cursor)
    let value_len = read_u16(page, cursor + 2)
    guard value_len <= max_value_len else { raise DbError::Corrupt }
    guard cursor + 4 + key_len + value_len <= page_size else {
      raise DbError::Corrupt
    }
    let key = owned_bytes(page[cursor + 4:cursor + 4 + key_len])
    if entries.last() is Some(previous) && compare_bytes(previous.key, key) >= 0 {
      raise DbError::Corrupt
    }
    let value = owned_bytes(
      page[cursor + 4 + key_len:cursor + 4 + key_len + value_len],
    )
    entries.push({ key, value, })
    cursor = cursor + 4 + key_len + value_len
  }
  { entries, right, }
}

///|
fn encode_branch(branch : Branch) -> FixedArray[Byte] raise DbError {
  guard branch.children.length() == branch.keys.length() + 1 else {
    raise DbError::Corrupt
  }
  let page = blank_page()
  page[0] = kind_branch
  write_u16(page, 1, branch.keys.length())
  let mut cursor = 3
  for child in branch.children {
    guard cursor + 4 <= page_size else { raise DbError::Corrupt }
    write_u32(page, cursor, child.reinterpret_as_uint())
    cursor = cursor + 4
  }
  for key in branch.keys {
    guard cursor + 2 + key.length() <= page_size else {
      raise DbError::ValueTooLarge
    }
    write_u16(page, cursor, key.length())
    page.blit_from_bytes(cursor + 2, key, 0, key.length())
    cursor = cursor + 2 + key.length()
  }
  page
}

///|
fn decode_branch(page : Bytes) -> Branch raise DbError {
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
    let key = owned_bytes(page[cursor + 2:cursor + 2 + key_len])
    if keys.last() is Some(previous) && compare_bytes(previous, key) >= 0 {
      raise DbError::Corrupt
    }
    keys.push(key)
    cursor = cursor + 2 + key_len
  }
  { keys, children, }
}

///|
fn encode_free(next : Int) -> FixedArray[Byte] {
  let page = blank_page()
  page[0] = kind_free
  write_u32(page, 1, next.reinterpret_as_uint())
  page
}

///|
fn decode_free(page : Bytes) -> Int raise DbError {
  guard page.length() == page_size && page[0] == kind_free else {
    raise DbError::Corrupt
  }
  let next = read_u32(page, 1).reinterpret_as_int()
  guard next >= 0 else { raise DbError::Corrupt }
  next
}

///|
fn decode_node(page : Bytes) -> Node raise DbError {
  guard page.length() == page_size else { raise DbError::Corrupt }
  match page[0] {
    b'\x01' => Leaf(decode_leaf(page))
    b'\x02' => Branch(decode_branch(page))
    b'\x03' => {
      let _ = decode_free(page)
      Free
    }
    _ => raise DbError::Corrupt
  }
}
