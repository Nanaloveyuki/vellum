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
