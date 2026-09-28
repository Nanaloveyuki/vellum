///|
fn key_of(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
test "empty tree misses every key" {
  let tree = Tree::new()
  let found = tree.get(key_of("a")) catch { err => fail("\{err}") }
  assert_true(found is None)
}

///|
test "put get overwrite and delete stay ordered" {
  let tree = Tree::new()
  let keys = ["m", "a", "z", "b", "a"]
  for name in keys {
    tree.put(key_of(name), key_of("v-\{name}")) catch {
      err => fail("\{err}")
    }
  }
  tree.put(key_of("a"), key_of("replaced")) catch {
    err => fail("\{err}")
  }
  let got = tree.get(key_of("a")) catch { err => fail("\{err}") }
  assert_eq(got, Some(key_of("replaced")))
  let ordered = tree.keys() catch { err => fail("\{err}") }
  inspect(ordered.length(), content="4")
  assert_eq(ordered[0], key_of("a"))
  assert_eq(ordered[1], key_of("b"))
  assert_eq(ordered[2], key_of("m"))
  assert_eq(ordered[3], key_of("z"))
  let removed = tree.delete(key_of("m")) catch { err => fail("\{err}") }
  assert_true(removed)
  let missing = tree.get(key_of("m")) catch { err => fail("\{err}") }
  assert_true(missing is None)
  let still = tree.delete(key_of("m")) catch { err => fail("\{err}") }
  assert_false(still)
}

///|
test "fixed sequence splits leaves and still finds every key" {
  let tree = Tree::new()
  for i in 0..<80 {
    let name = if i < 10 { "0\{i}" } else { "\{i}" }
    tree.put(key_of(name), key_of("value-\{name}-\{name}")) catch {
      err => fail("\{err}")
    }
  }
  let ordered = tree.keys() catch { err => fail("\{err}") }
  inspect(ordered.length(), content="80")
  assert_eq(ordered[0], key_of("00"))
  assert_eq(ordered[79], key_of("79"))
  let middle = tree.get(key_of("40")) catch { err => fail("\{err}") }
  assert_eq(middle, Some(key_of("value-40-40")))
  for i in 0..<80 {
    if i % 2 == 0 {
      let name = if i < 10 { "0\{i}" } else { "\{i}" }
      let removed = tree.delete(key_of(name)) catch { err => fail("\{err}") }
      assert_true(removed)
    }
  }
  let left = tree.keys() catch { err => fail("\{err}") }
  inspect(left.length(), content="40")
  let odd = tree.get(key_of("41")) catch { err => fail("\{err}") }
  assert_eq(odd, Some(key_of("value-41-41")))
}

///|
test "value larger than one page is rejected" {
  let tree = Tree::new()
  let huge = Bytes::make(max_value_len + 1, b'\x01')
  try tree.put(key_of("big"), huge) catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected ValueTooLarge")
  }
}
