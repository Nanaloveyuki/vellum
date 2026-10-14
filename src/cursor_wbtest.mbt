///|
async fn cursor_error(cursor : Cursor, expected : DbError) -> Unit {
  try cursor.next() catch {
    error => assert_eq(error, expected)
  } noraise {
    _ => fail("expected \{expected}")
  }
}

///|
async test "cursor crosses empty leaves without seeking again" {
  let dir = @fs.tmpdir(prefix="vellum-cursor-empty")
  defer @fs.rmdir(dir, recursive=true)
  let db = open("\{dir}/db")
  let txn = db.begin()
  let tree = db.tree
  tree.root = 4
  tree.next_page = 5
  tree.pages[1] = page_bytes(
    encode_leaf({ entries: [{ key: b"a", value: b"one", }], right: 2, }),
  )
  tree.pages[2] = page_bytes(encode_leaf({ entries: [], right: 3, }))
  tree.pages[3] = page_bytes(
    encode_leaf({ entries: [{ key: b"z", value: b"two", }], right: 0, }),
  )
  tree.pages[4] = page_bytes(
    encode_branch({ keys: [b"m", b"z"], children: [1, 2, 3], }),
  )
  tree.validate()
  let cursor = txn.scan(b"")
  assert_eq(cursor.next(), Some((b"a", b"one")))
  assert_eq(cursor.next(), Some((b"z", b"two")))
  assert_eq(cursor.next(), None)
  assert_eq(cursor.next(), None)
  let cursor = txn.scan(b"m")
  assert_eq(cursor.next(), Some((b"z", b"two")))
  txn.abort()
  db.close()
}

///|
async test "cursor state priority precedes invalidation and EOF during commit and failure" {
  let dir = @fs.tmpdir(prefix="vellum-cursor-state")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = open(path)
  let txn = db.begin()
  txn.put(b"a", b"one")
  let cursor = txn.scan(b"", end=b"")
  assert_eq(cursor.next(), None)
  txn.put(b"a", b"one")
  txn.commit_until(pause_after_wal=true)
  cursor_error(cursor, DbError::TxnBusy)
  try txn.scan(b"z", end=b"a") catch {
    DbError::TxnBusy => ()
    error => fail("\{error}")
  } noraise {
    _ => fail("busy scan accepted")
  }
  db.closed = true
  cursor_error(cursor, DbError::Closed)
  let recovered = open(path)
  let read = recovered.begin()
  assert_eq(read.get(b"a"), Some(b"one"))
  read.abort()
  recovered.close()
  let path = "\{dir}/fail"
  let db = open(path)
  let txn = db.begin()
  txn.put(b"a", b"one")
  let cursor = txn.scan(b"", end=b"")
  txn.put(b"a", b"one")
  @fs.mkdir(path)
  try txn.commit() catch {
    DbError::Io(_) => ()
    error => fail("\{error}")
  } noraise {
    _ => fail("checkpoint unexpectedly succeeded")
  }
  cursor_error(cursor, DbError::RecoveryRequired)
  try txn.scan(b"z", end=b"a") catch {
    DbError::RecoveryRequired => ()
    error => fail("\{error}")
  } noraise {
    _ => fail("failed scan accepted")
  }
  db.close()
  cursor_error(cursor, DbError::Closed)
}

///|
async test "cancelled commit cursor requires recovery before invalidation or EOF" {
  let dir = @fs.tmpdir(prefix="vellum-cursor-cancel")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = open(path)
  let txn = db.begin()
  for i in 0..<256 {
    txn.put(@utf8.encode("key-\{i}"), Bytes::make(3000, b'x'))
  }
  let cursor = txn.scan(b"", end=b"")
  @async.with_task_group(async fn(group) {
    let writer = group.spawn(async fn() { txn.commit() })
    while txn.state is Active {
      @async.pause()
    }
    writer.cancel()
    try writer.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => fail("\{error}")
    } noraise {
      _ => fail("cancelled commit completed")
    }
  })
  cursor_error(cursor, DbError::RecoveryRequired)
  db.close()
  cursor_error(cursor, DbError::Closed)
}
