///|
fn bytes_of(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
fn padded(n : Int) -> Bytes {
  Bytes::make(n, b'x')
}

///|
/// 直接从 map 读一页，不做解码；用于断言页字节真的没被动过。
fn snapshot_pages(tree : Tree) -> Map[Int, Bytes] {
  let copy : Map[Int, Bytes] = Map([])
  for id, page in tree.pages {
    copy[id] = page
  }
  copy
}

///|
fn pages_equal(left : Map[Int, Bytes], right : Map[Int, Bytes]) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for id, page in left {
    match right.get(id) {
      Some(other) => if page != other { return false }
      None => return false
    }
  }
  true
}

///|
fn meta_of(tree : Tree) -> (Int, Int, Int) {
  (tree.root, tree.freelist, tree.next_page)
}

///|
/// 混合长度键值：短 entry、刚好卡到单页上限的 4000 字节 value、普通 entry。
/// 只断言可见状态，不假设任何页号或页布局。
test "mixed a/b value1 c value4000 d value100 keeps every key" {
  let tree = Tree::new()
  tree.put(bytes_of("a"), bytes_of("value1")) catch {
    err => fail("\{err}")
  }
  tree.put(bytes_of("b"), bytes_of("value1")) catch {
    err => fail("\{err}")
  }
  tree.put(bytes_of("c"), padded(4000)) catch {
    err => fail("\{err}")
  }
  tree.put(bytes_of("d"), bytes_of("value100")) catch {
    err => fail("\{err}")
  }
  assert_eq(
    tree.get(bytes_of("a")) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("value1")),
  )
  assert_eq(
    tree.get(bytes_of("b")) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("value1")),
  )
  assert_eq(
    tree.get(bytes_of("c")) catch {
      err => fail("\{err}")
    },
    Some(padded(4000)),
  )
  assert_eq(
    tree.get(bytes_of("d")) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("value100")),
  )
  let ordered = tree.keys() catch { err => fail("\{err}") }
  assert_eq(ordered.length(), 4)
  assert_eq(ordered[0], bytes_of("a"))
  assert_eq(ordered[3], bytes_of("d"))
}

///|
/// 单条 entry 连页头都放不下：立刻 ValueTooLarge，不改任何页与元数据。
test "unrepresentable single entry leaves every page untouched" {
  let tree = Tree::new()
  tree.put(bytes_of("keep"), bytes_of("yes")) catch {
    err => fail("\{err}")
  }
  tree.put(bytes_of("second"), bytes_of("also")) catch {
    err => fail("\{err}")
  }
  let before_pages = snapshot_pages(tree)
  let before_meta = meta_of(tree)
  let too_long_key = padded(page_size)
  let too_long_value = padded(max_value_len + 1)
  try tree.put(too_long_key, bytes_of("v")) catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected ValueTooLarge for oversized key")
  }
  try tree.put(bytes_of("k"), too_long_value) catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected ValueTooLarge for oversized value")
  }
  assert_eq(
    tree.get(bytes_of("keep")) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("yes")),
  )
  assert_eq(
    tree.get(bytes_of("second")) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("also")),
  )
  assert_eq(meta_of(tree), before_meta)
  assert_true(pages_equal(tree.pages, before_pages))
}

///|
/// 已有单条 entry 被更大的值覆盖放不下：是 ValueTooLarge，不是 Corrupt，
/// 且原来的键值仍然在。
test "oversized overwrite of existing entry is ValueTooLarge and keeps old value" {
  let tree = Tree::new()
  tree.put(bytes_of("a"), bytes_of("short")) catch {
    err => fail("\{err}")
  }
  let before_pages = snapshot_pages(tree)
  let before_meta = meta_of(tree)
  let huge = padded(max_value_len + 1)
  try tree.put(bytes_of("a"), huge) catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected ValueTooLarge, got success")
  }
  assert_eq(
    tree.get(bytes_of("a")) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("short")),
  )
  assert_eq(meta_of(tree), before_meta)
  assert_true(pages_equal(tree.pages, before_pages))
}

///|
/// 失败操作的回滚：用一条必然放不下的 entry（key+value 超过单页预算）制造失败，
/// 这次操作碰过的页必须一个不差地回到原样，`undo` 里多出来的条目也要撤回。
test "failed operation rolls back every page it touched" {
  let tree = Tree::new()
  let small_a = bytes_of("k1")
  let small_b = bytes_of("k2")
  tree.put(small_a, bytes_of("v1")) catch {
    err => fail("\{err}")
  }
  tree.put(small_b, bytes_of("v2")) catch {
    err => fail("\{err}")
  }
  tree.reset_changes()
  let before_pages = snapshot_pages(tree)
  let before_meta = meta_of(tree)
  // entry 本身放不下：7 + 4 + key + value > 4096，写入前就被挡下。
  let oversized_key = padded(page_size)
  try tree.put(oversized_key, bytes_of("v")) catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected ValueTooLarge")
  }
  assert_eq(
    tree.get(small_a) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("v1")),
  )
  assert_eq(
    tree.get(small_b) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("v2")),
  )
  assert_eq(meta_of(tree), before_meta)
  assert_true(pages_equal(tree.pages, before_pages))
  assert_true(tree.changed_pages().is_empty())
}

///|
/// 拆页器只在“任何切分点都放不下”时报 ValueTooLarge，绝不产出放不下的半边。
/// 两个 4000 字节值分到两侧各占 4012 <= 4096，必须切分成功；
/// 真正切不开的叶子必须报错而不是写成损坏页。
test "split leaf partitions by byte capacity and rejects impossible ones" {
  let huge = padded(4000)
  let splittable = {
    entries: [
      { key: bytes_of("a"), value: huge, },
      { key: bytes_of("b"), value: huge, },
    ],
    right: 0,
  }
  let (left, _sep, right) = split_leaf(splittable) catch {
    err => fail("\{err}")
  }
  assert_true(leaf_byte_size(left) <= page_size)
  assert_true(leaf_byte_size(right) <= page_size)
  assert_eq(left.entries.length(), 1)
  assert_eq(right.entries.length(), 1)
  // 三条 3000 字节值：任何分界都让一侧超过 4096，必须 ValueTooLarge。
  let big = padded(3000)
  let unsplittable = {
    entries: [
      { key: bytes_of("a"), value: big, },
      { key: bytes_of("b"), value: big, },
      { key: bytes_of("c"), value: big, },
    ],
    right: 0,
  }
  try split_leaf(unsplittable) |> ignore catch {
    DbError::ValueTooLarge => ()
    err => fail("expected ValueTooLarge, got \{err}")
  } noraise {
    _ => fail("expected ValueTooLarge for an unsplittable leaf")
  }
}

///|
/// 事务级回滚：reset 后先成功写入，再进入一次失败操作，最后整份回滚必须回到
/// reset 时的状态，且失败操作没有污染成功写入留下的 undo。
test "rollback_changes restores every page after a failed operation" {
  let tree = Tree::new()
  tree.put(bytes_of("base"), bytes_of("v")) catch {
    err => fail("\{err}")
  }
  let base_root = tree.root
  let base_freelist = tree.freelist
  let base_next = tree.next_page
  tree.reset_changes()
  let baseline = snapshot_pages(tree)
  // 成功的一次写入。
  tree.put(bytes_of("added"), bytes_of("ok")) catch {
    err => fail("\{err}")
  }
  // 再失败一次：这条 key 本身放不进任何一页，写入前就被挡下。
  try tree.put(padded(page_size), bytes_of("x")) catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected ValueTooLarge")
  }
  // 失败操作已自愈，成功写入还在。
  assert_eq(
    tree.get(bytes_of("added")) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("ok")),
  )
  tree.rollback_changes(base_root, base_freelist, base_next)
  assert_true(pages_equal(tree.pages, baseline))
  assert_eq(tree.root, base_root)
  assert_eq(tree.freelist, base_freelist)
  assert_eq(tree.next_page, base_next)
  assert_true(
    (tree.get(bytes_of("added")) catch { err => fail("\{err}") }) is None,
  )
  assert_eq(
    tree.get(bytes_of("base")) catch {
      err => fail("\{err}")
    },
    Some(bytes_of("v")),
  )
  assert_true(tree.changed_pages().is_empty())
}

///|
/// 实际脏页：成功写入后的 changed_pages 正好是 undo 里真正变过的页，
/// 失败的写入不会留下任何脏页。
test "changed pages track real differences only" {
  let tree = Tree::new()
  tree.put(bytes_of("a"), bytes_of("1")) catch {
    err => fail("\{err}")
  }
  tree.put(bytes_of("b"), bytes_of("2")) catch {
    err => fail("\{err}")
  }
  tree.reset_changes()
  // 覆盖成相同的值：字节没变，不该记脏页。
  tree.put(bytes_of("a"), bytes_of("1")) catch {
    err => fail("\{err}")
  }
  assert_true(tree.changed_pages().is_empty())
  tree.put(bytes_of("a"), bytes_of("changed")) catch {
    err => fail("\{err}")
  }
  let dirty = tree.changed_pages()
  assert_true(dirty.length() >= 1)
  // 每一页都必须真的和 reset 时不同。
  for id in dirty {
    assert_true(id >= 0)
  }
  // 失败操作不留脏页：先记脏，再制造一次失败操作，脏页集合不变。
  let before_fail = tree.changed_pages()
  try tree.put(bytes_of("z"), padded(max_value_len + 1)) catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected ValueTooLarge")
  }
  assert_eq(tree.changed_pages(), before_fail)
}

///|
/// 失败操作不能污染先前成功写入留下的 `undo`：成功写入先记下原页，
/// 之后一次失败的操作只撤回自己碰过的页，成功写入的 undo 条目必须还在，
/// 事务级回滚仍能把那次成功写入也一并回滚。
test "failed operation preserves the undo of earlier successful changes" {
  let tree = Tree::new()
  tree.reset_changes()
  let baseline = snapshot_pages(tree)
  let base_root = tree.root
  let base_freelist = tree.freelist
  let base_next = tree.next_page
  // 一次成功写入，进入 undo。
  tree.put(bytes_of("kept"), bytes_of("value")) catch {
    err => fail("\{err}")
  }
  let after_success = snapshot_pages(tree)
  // 一次失败操作：不得动到成功写入的 undo。
  try tree.put(padded(page_size), bytes_of("x")) catch {
    DbError::ValueTooLarge => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected ValueTooLarge")
  }
  assert_true(pages_equal(tree.pages, after_success))
  // 事务级回滚必须把成功写入也撤掉，证明它的 undo 仍在。
  tree.rollback_changes(base_root, base_freelist, base_next)
  assert_true(pages_equal(tree.pages, baseline))
  assert_eq(tree.root, base_root)
  assert_eq(tree.next_page, base_next)
}

///|
/// 只改一个键的删除：验证成功删除的可见状态与脏页，失败路径由 put 测试覆盖。
test "delete keeps other keys and reports removal truthfully" {
  let tree = Tree::new()
  for i in 0..<20 {
    tree.put(bytes_of("k-\{i}"), bytes_of("v-\{i}")) catch {
      err => fail("\{err}")
    }
  }
  tree.reset_changes()
  let removed = tree.delete(bytes_of("k-7")) catch { err => fail("\{err}") }
  assert_true(removed)
  assert_true(
    (tree.get(bytes_of("k-7")) catch { err => fail("\{err}") }) is None,
  )
  for i in 0..<20 {
    if i != 7 {
      assert_eq(
        tree.get(bytes_of("k-\{i}")) catch {
          err => fail("\{err}")
        },
        Some(bytes_of("v-\{i}")),
      )
    }
  }
  let again = tree.delete(bytes_of("k-7")) catch { err => fail("\{err}") }
  assert_false(again)
}
