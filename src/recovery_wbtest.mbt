///|
async test "complete redo repairs torn header and tail while retaining unchanged pages" {
  for tear_header in [false, true] {
    let dir = @fs.tmpdir(prefix="vellum-redo")
    defer @fs.rmdir(dir, recursive=true)
    let path = "\{dir}/db"
    let db = open(path)
    let first = db.begin()
    first.put(b"a", Bytes::make(3000, b'u'))
    first.put(b"z", Bytes::make(3000, b'a'))
    first.commit()
    let second = db.begin()
    second.put(b"z", Bytes::make(3000, b'b'))
    second.put(b"zz", Bytes::make(3000, b'n'))
    second.commit_until(pause_after_wal=true)
    let raw = read_all_bytes(path)
    let torn = FixedArray::make(raw.length(), b'\x00')
    torn.blit_from_bytes(0, raw, 0, raw.length())
    if tear_header {
      torn[0] = b'\x00'
      write_synced_bytes(path, fixed_to_bytes(torn))
    } else {
      write_synced_bytes(path, raw[:raw.length() - 1].to_owned())
    }
    db.closed = true
    let recovered = open(path)
    let read = recovered.begin()
    assert_eq(read.get(b"a"), Some(Bytes::make(3000, b'u')))
    assert_eq(read.get(b"z"), Some(Bytes::make(3000, b'b')))
    assert_eq(read.get(b"zz"), Some(Bytes::make(3000, b'n')))
    read.abort()
    let third = recovered.begin()
    third.put(b"after", b"three")
    third.commit()
    recovered.close()
    let again = open(path)
    let read = again.begin()
    assert_eq(read.get(b"a"), Some(Bytes::make(3000, b'u')))
    assert_eq(read.get(b"z"), Some(Bytes::make(3000, b'b')))
    assert_eq(read.get(b"zz"), Some(Bytes::make(3000, b'n')))
    assert_eq(read.get(b"after"), Some(b"three"))
    read.abort()
    again.close()
  }
}

///|
async test "missing unchanged pages cannot be invented by redo" {
  let dir = @fs.tmpdir(prefix="vellum-missing")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = open(path)
  let first = db.begin()
  first.put(b"untouched", Bytes::make(3000, b'u'))
  first.put(b"changed", Bytes::make(3000, b'a'))
  first.commit()
  let next = db.begin()
  next.put(b"changed", Bytes::make(3000, b'b'))
  next.commit_until(pause_after_wal=true)
  write_synced_bytes(path, b"")
  db.closed = true
  let before = read_all_bytes(wal_path(path))
  try open(path) catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("missing unchanged pages accepted")
  }
  assert_eq(read_all_bytes(wal_path(path)), before)
}

///|
async test "failed page checkpoint blocks rollback and recovers committed WAL" {
  let dir = @fs.tmpdir(prefix="vellum-failed-checkpoint")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = open(path)
  let txn = db.begin()
  txn.put(b"committed", b"yes")
  @fs.mkdir(path)
  try txn.commit() catch {
    DbError::Io(_) => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("directory checkpoint accepted")
  }
  try txn.abort() catch {
    DbError::RecoveryRequired => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("failed commit rollback accepted")
  }
  try db.begin() catch {
    DbError::RecoveryRequired => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("failed commit begin accepted")
  }
  db.close()
  @fs.rmdir(path)
  let recovered = open(path)
  let read = recovered.begin()
  assert_eq(read.get(b"committed"), Some(b"yes"))
  read.abort()
  recovered.close()
}
