///|
test "malformed node ordering and negative links are rejected" {
  let unsorted = page_bytes(
    encode_leaf({
      entries: [{ key: b"z", value: b"one", }, { key: b"a", value: b"two", }],
      right: 0,
    }),
  )
  try decode_node(unsorted) catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("unsorted leaf accepted")
  }
  let bad_branch = page_bytes(encode_branch({ keys: [], children: [-1], }))
  try decode_node(bad_branch) catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("negative child accepted")
  }
  let bad_free = page_bytes(encode_free(-1))
  try decode_free(bad_free) catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("negative free link accepted")
  }
}

///|
test "graph cycles are rejected without recursive lookup" {
  let tree = Tree::new()
  tree.root = 1
  tree.next_page = 2
  tree.pages[1] = page_bytes(encode_branch({ keys: [], children: [1], }))
  try tree.validate() catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("branch cycle accepted")
  }
  tree.root = 0
  tree.freelist = 1
  tree.pages[1] = page_bytes(encode_free(1))
  try tree.validate() catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("freelist cycle accepted")
  }
}
