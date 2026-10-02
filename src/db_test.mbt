///|
async fn fresh_path() -> String {
  let dir = @fs.tmpdir(prefix="vellum")
  "\{dir}/vellum.db"
}

///|
async test "commit is visible after reopen and abort is not" {
  let path = fresh_path()
  let db = @vellum.open(path)
  let txn = db.begin()
  txn.put(b"alpha", b"one")
  txn.abort()
  let again = db.begin()
  let hidden = again.get(b"alpha")
  assert_true(hidden is None)
  again.put(b"alpha", b"one")
  again.put(b"beta", b"two")
  again.commit()
  db.close()
  let reopened = @vellum.open(path)
  let read = reopened.begin()
  assert_eq(read.get(b"alpha"), Some(b"one"))
  assert_eq(read.get(b"beta"), Some(b"two"))
  read.abort()
  reopened.close()
}

///|
async test "a torn wal tail is discarded and the committed prefix stays" {
  let path = fresh_path()
  let db = @vellum.open(path)
  let txn = db.begin()
  txn.put(b"kept", b"yes")
  txn.commit()
  db.close()
  let wal = "\{path}.wal"
  @fs.write_file(wal, b"\x01\x02", create_mode=@fs.CreateOrTruncate)
  let reopened = @vellum.open(path)
  let read = reopened.begin()
  assert_eq(read.get(b"kept"), Some(b"yes"))
  read.abort()
  reopened.close()
}

///|
async test "uncommitted close drops the write" {
  let path = fresh_path()
  let db = @vellum.open(path)
  let txn = db.begin()
  txn.put(b"lost", b"no")
  db.close()
  let reopened = @vellum.open(path)
  let read = reopened.begin()
  assert_true(read.get(b"lost") is None)
  read.abort()
  reopened.close()
}

///|
async fn expect_ended(txn : @vellum.Txn) -> Unit {
  try txn.get(b"kept") catch {
    @vellum.DbError::TxnClosed => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("ended get accepted")
  }
  try txn.put(b"stale", b"wrong") catch {
    @vellum.DbError::TxnClosed => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("ended put accepted")
  }
  try txn.delete(b"kept") catch {
    @vellum.DbError::TxnClosed => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("ended delete accepted")
  }
  try txn.commit() catch {
    @vellum.DbError::TxnClosed => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("ended commit accepted")
  }
  try txn.abort() catch {
    @vellum.DbError::TxnClosed => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("ended abort accepted")
  }
}

///|
async test "ended handles cannot alter a later transaction" {
  let path = fresh_path()
  let db = @vellum.open(path)
  let committed = db.begin()
  committed.put(b"kept", b"yes")
  committed.commit()
  let aborted = db.begin()
  aborted.put(b"discarded", b"no")
  aborted.abort()
  let current = db.begin()
  current.put(b"new", b"yes")
  expect_ended(committed)
  expect_ended(aborted)
  assert_eq(current.get(b"kept"), Some(b"yes"))
  assert_eq(current.get(b"new"), Some(b"yes"))
  assert_eq(current.get(b"stale"), None)
  assert_eq(current.get(b"discarded"), None)
  current.commit()
  db.close()
  let reopened = @vellum.open(path)
  let read = reopened.begin()
  assert_eq(read.get(b"kept"), Some(b"yes"))
  assert_eq(read.get(b"new"), Some(b"yes"))
  read.abort()
  reopened.close()
}
