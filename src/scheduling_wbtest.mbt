///|
async test "cancelled cooperative batch can abort without losing committed data" {
  let dir = @fs.tmpdir(prefix="vellum-cancel-batch")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = open(path)
  let first = db.begin()
  first.put(b"kept", b"old")
  first.commit()
  let txn = db.begin()
  let mut ready = false
  @async.with_task_group(async fn(group) {
    let writer = group.spawn(async fn() {
      for i in 0..<256 {
        txn.put(@utf8.encode("key-\{i}"), Bytes::make(64, b'x'))
      }
      ready = true
      @async.sleep(10000)
      txn.commit()
    })
    while !ready {
      @async.pause()
    }
    writer.cancel()
    try writer.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => fail("\{err}")
    } noraise {
      _ => fail("cancelled batch completed")
    }
  })
  assert_eq(txn.get(b"key-0"), Some(Bytes::make(64, b'x')))
  txn.abort()
  let read = db.begin()
  assert_eq(read.get(b"kept"), Some(b"old"))
  assert_eq(read.get(b"key-0"), None)
  read.abort()
  db.close()
  let db = open(path)
  let read = db.begin()
  assert_eq(read.get(b"kept"), Some(b"old"))
  assert_eq(read.get(b"key-0"), None)
  read.abort()
  db.close()
}

///|
async test "cancelled commit requires recovery and permits a verified subsequent commit" {
  let dir = @fs.tmpdir(prefix="vellum-cancel-commit")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = open(path)
  let first = db.begin()
  first.put(b"kept", b"old")
  first.commit()
  let txn = db.begin()
  for i in 0..<256 {
    txn.put(@utf8.encode("key-\{i}"), Bytes::make(3000, b'x'))
  }
  @async.with_task_group(async fn(group) {
    let writer = group.spawn(async fn() { txn.commit() })
    while txn.state is Active {
      @async.pause()
    }
    writer.cancel()
    try writer.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => fail("\{err}")
    } noraise {
      _ => fail("cancelled commit completed")
    }
  })
  try txn.abort() catch {
    DbError::RecoveryRequired => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("cancelled commit allowed rollback")
  }
  db.close()
  let db = open(path)
  let read = db.begin()
  assert_eq(read.get(b"kept"), Some(b"old"))
  let first_value = read.get(b"key-0")
  for i in 0..<256 {
    assert_eq(read.get(@utf8.encode("key-\{i}")), first_value)
  }
  assert_true(
    first_value is None || first_value == Some(Bytes::make(3000, b'x')),
  )
  read.abort()
  let next = db.begin()
  next.put(b"after", b"yes")
  next.commit()
  db.close()
  let db = open(path)
  let read = db.begin()
  assert_eq(read.get(b"kept"), Some(b"old"))
  assert_eq(read.get(b"after"), Some(b"yes"))
  for i in 0..<256 {
    assert_eq(read.get(@utf8.encode("key-\{i}")), first_value)
  }
  read.abort()
  db.close()
}
