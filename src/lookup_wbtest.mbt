///|
test "borrowed lookup preserves shortlex boundaries and exact values" {
  let tree = Tree::new()
  let keys = [b"", b"a", b"z", b"\xff", b"\x00\x00", b"aa", b"aaa"]
  for i in 0..<keys.length() {
    tree.put(keys[i], Bytes::make(1024, i.to_byte()))
  }
  assert_eq(tree.keys(), keys)
  for i in 0..<keys.length() {
    assert_eq(tree.get(keys[i]), Some(Bytes::make(1024, i.to_byte())))
  }
  assert_eq(tree.get(b"b"), None)
  assert_eq(tree.get(b"ab"), None)
  assert_eq(tree.get(b"aaaa"), None)
  tree.put(b"z", b"changed")
  assert_eq(tree.get(b"z"), Some(b"changed"))
  assert_true(tree.delete(b"aa"))
  assert_eq(tree.get(b"aa"), None)
  assert_eq(tree.get(b"aaa"), Some(Bytes::make(1024, 6)))
}

///|
test "lookup rejects cyclic child links without recursion" {
  let tree = Tree::new()
  tree.root = 1
  tree.next_page = 2
  tree.pages[1] = page_bytes(encode_branch({ keys: [], children: [1], }))
  try tree.get(b"a") catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("cyclic lookup accepted")
  }
}
