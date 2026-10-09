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

///|
test "indexed reads follow rollback reuse and eviction without leaking old values" {
  let tree = Tree::new()
  let keys = [ for i in 0..<600 => @utf8.encode("key-\{1000 + i}") ]
  for i in 0..<keys.length() {
    tree.put(keys[i], Bytes::make(3000, i.to_byte()))
  }
  for i in 0..<keys.length() {
    assert_eq(tree.get(keys[i]), Some(Bytes::make(3000, i.to_byte())))
  }
  let retained = tree.get(keys[0])
  let (root, freelist, next) = (tree.root, tree.freelist, tree.next_page)
  tree.reset_changes()
  for i in 0..<300 {
    assert_true(tree.delete(keys[i]))
  }
  for i in 0..<300 {
    tree.put(keys[i], b"replacement")
    assert_eq(tree.get(keys[i]), Some(b"replacement"))
  }
  tree.rollback_changes(root, freelist, next)
  for i in 0..<keys.length() {
    assert_eq(tree.get(keys[i]), Some(Bytes::make(3000, i.to_byte())))
  }
  assert_eq(retained, Some(Bytes::make(3000, 0)))
  tree.validate()
}

///|
test "a warmed page index cannot hide a malformed replacement" {
  let tree = Tree::new()
  tree.put(b"a", b"old")
  assert_eq(tree.get(b"a"), Some(b"old"))
  let original = tree.pages[tree.root]
  let malformed = page_bytes(
    encode_leaf({
      entries: [{ key: b"z", value: b"wrong", }, { key: b"a", value: b"bad", }],
      right: 0,
    }),
  )
  tree.begin_operation()
  tree.set_page(tree.root, malformed)
  try tree.get(b"a") catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("malformed replacement bypassed validation")
  }
  tree.rollback_operation()
  assert_eq(tree.pages[tree.root], original)
  assert_eq(tree.get(b"a"), Some(b"old"))
}

///|
test "failed parent decoding discards cached mutable changes and preserves earlier writes" {
  let tree = Tree::new()
  tree.put(b"a", b"old")
  tree.put(b"zz", b"kept")
  let leaf_id = tree.root
  let (root, freelist, next) = (tree.root, tree.freelist, tree.next_page)
  tree.reset_changes()
  tree.put(b"a", b"earlier")
  assert_eq(tree.get(b"a"), Some(b"earlier"))
  let good_root = tree.root
  let fake_parent = tree.next_page
  tree.pages[fake_parent] = page_bytes(
    encode_branch({ keys: [], children: [-1], }),
  )
  tree.next_page += 1
  tree.root = fake_parent
  try {
    tree.begin_operation()
    errdefer tree.rollback_operation()
    let leaf = match tree.load(leaf_id) {
      Leaf(leaf) => leaf
      _ => fail("expected leaf")
    }
    leaf.entries[0] = { key: b"a", value: b"failed", }
    tree.store_leaf(leaf_id, leaf)
    tree.load(fake_parent) |> ignore
    tree.commit_operation()
  } catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("bad parent accepted")
  }
  tree.pages.remove(fake_parent)
  tree.root = good_root
  tree.next_page -= 1
  assert_eq(tree.get(b"a"), Some(b"earlier"))
  let leaf = match tree.load(leaf_id) {
    Leaf(leaf) => leaf
    _ => fail("expected leaf")
  }
  assert_eq(leaf.entries[0].value, b"earlier")
  tree.put(b"a", b"continued")
  assert_eq(tree.get(b"a"), Some(b"continued"))
  tree.rollback_changes(root, freelist, next)
  assert_eq(tree.get(b"a"), Some(b"old"))
  assert_eq(tree.get(b"zz"), Some(b"kept"))
  tree.validate()
}
