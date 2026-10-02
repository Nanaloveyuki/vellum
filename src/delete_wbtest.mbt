///|
test "long keys delete through single-child branches without losing siblings" {
  let tree = Tree::new()
  let keys = [
    Bytes::make(3000, b'a'),
    Bytes::make(3000, b'b'),
    Bytes::make(3000, b'c'),
  ]
  for key in keys {
    tree.put(key, b"")
  }
  assert_true(tree.delete(keys[2]))
  assert_eq(tree.get(keys[0]), Some(b""))
  assert_eq(tree.get(keys[1]), Some(b""))
  assert_eq(tree.get(keys[2]), None)
  assert_true(tree.delete(keys[0]))
  assert_eq(tree.get(keys[1]), Some(b""))
  assert_true(tree.delete(keys[1]))
  assert_eq(tree.keys(), [])
  for key in keys {
    tree.put(key, b"again")
  }
  for key in keys {
    assert_eq(tree.get(key), Some(b"again"))
  }
}

///|
test "multi-level deletion and reinsertion preserve exact contents" {
  let tree = Tree::new()
  let count = 1100
  let value = Bytes::make(4000, b'v')
  for i in 0..<count {
    let key = Bytes::from_array([i / 256, i % 256].map(x => x.to_byte()))
    tree.put(key, value)
  }
  for i in 0..<count {
    let key = Bytes::from_array([i / 256, i % 256].map(x => x.to_byte()))
    assert_eq(tree.get(key), Some(value))
  }
  for i in 0..<count {
    let index = if i % 2 == 0 { i / 2 } else { count - 1 - i / 2 }
    let key = Bytes::from_array(
      [index / 256, index % 256].map(x => x.to_byte()),
    )
    assert_true(tree.delete(key))
    assert_eq(tree.get(key), None)
  }
  assert_eq(tree.keys(), [])
  for i in 0..<count {
    let key = Bytes::from_array([i / 256, i % 256].map(x => x.to_byte()))
    tree.put(key, value)
  }
  for i in 0..<count {
    let key = Bytes::from_array([i / 256, i % 256].map(x => x.to_byte()))
    assert_eq(tree.get(key), Some(value))
  }
}
