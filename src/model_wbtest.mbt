///|
fn model_order(left : Bytes, right : Bytes) -> Int {
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
fn model_key(index : Int) -> Bytes {
  let length = [0, 1, 2, 3, 12, 40][index % 6]
  if length == 0 {
    return b""
  }
  let bytes = FixedArray::make(length, b'k')
  bytes[0] = index.to_byte()
  Bytes::from_array(bytes)
}

///|
fn assert_model(
  tree : Tree,
  model : Map[Bytes, Bytes],
  keys : Array[Bytes],
) -> Unit raise {
  for key in keys {
    assert_eq(tree.get(key), model.get(key))
  }
  let expected = model.keys().collect()
  expected.sort_by(model_order)
  assert_eq(tree.keys(), expected)
}

///|
test "fixed-seed mixed-key operations agree with an independent map" {
  for seed in [20261002U, 8675309U, 424242U] {
    let tree = Tree::new()
    let model : Map[Bytes, Bytes] = Map([])
    let keys = Array::makei(96, model_key)
    for i in 0..<64 {
      let value = Bytes::make(1024, i.to_byte())
      tree.put(keys[i], value)
      model[keys[i]] = value
    }
    let mut random = seed
    for step in 0..<300 {
      random = random * 1664525U + 1013904223U
      let index = (random % 96U).reinterpret_as_int()
      let key = keys[index]
      let operation = (random >> 16) % 5U
      if operation <= 2U {
        let length = [0, 1, 128, 1024][(random >> 24).reinterpret_as_int() % 4]
        let value = Bytes::make(length, step.to_byte())
        tree.put(key, value)
        model[key] = value
      } else if operation == 3U {
        assert_eq(tree.delete(key), model.contains(key))
        model.remove(key)
      } else {
        try tree.put(key, Bytes::make(4001, b'x')) catch {
          DbError::ValueTooLarge => ()
          err => fail("seed=\{seed} step=\{step}: \{err}")
        } noraise {
          _ => fail("seed=\{seed} step=\{step}: oversized value accepted")
        }
      }
      assert_model(tree, model, keys)
    }
    let remaining = model.keys().collect()
    for key in remaining {
      assert_true(tree.delete(key))
      model.remove(key)
      assert_model(tree, model, keys)
    }
    for i in 0..<keys.length() {
      let value = Bytes::make(128, i.to_byte())
      tree.put(keys[i], value)
      model[keys[i]] = value
    }
    assert_model(tree, model, keys)
  }
}

///|
test "failed oversized key preserves earlier successful transaction changes" {
  let tree = Tree::new()
  let model : Map[Bytes, Bytes] = Map([])
  let keys = [b"a", b"b", b"c", b"d"]
  for i in 0..<keys.length() {
    let value = Bytes::make([1, 1, 4000, 100][i], b'x')
    tree.put(keys[i], value)
    model[keys[i]] = value
  }
  try tree.put(Bytes::make(4086, b'k'), b"") catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("oversized key accepted")
  }
  assert_model(tree, model, keys)
}
