///|
fn cursor_order(left : Bytes, right : Bytes) -> Int {
  for i, byte in left {
    if i >= right.length() {
      return 1
    }
    let difference = byte.to_int() - right[i].to_int()
    if difference != 0 {
      return difference
    }
  }
  left.length() - right.length()
}

///|
async fn cursor_rows(cursor : @vellum.Cursor) -> Array[(Bytes, Bytes)] {
  let rows = []
  while cursor.next() is Some(row) {
    rows.push(row)
  }
  assert_eq(cursor.next(), None)
  rows
}

///|
async fn expect_cursor_error(
  cursor : @vellum.Cursor,
  expected : @vellum.DbError,
) -> Unit {
  try cursor.next() catch {
    error => assert_eq(error, expected)
  } noraise {
    _ => fail("cursor accepted after \{expected}")
  }
}

///|
async test "public cursor matches independent binary ranges prefixes and reopened rows" {
  let dir = @fs.tmpdir(prefix="vellum-cursor")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = @vellum.open(path)
  let txn = db.begin()
  let keys = [
    b"", b"\x00", b"\x00\xff", b"a", b"a\x00", b"aa", b"a\xff", b"a\xff\x00", b"a\xff\xff",
    b"b", b"z", b"\x80", b"\xff", b"\xff\xff", b"\xff\xff\x00",
  ]
  for i in 0..<96 {
    keys.push(@utf8.encode("key-\{1000 + i}"))
  }
  let model : Map[Bytes, Bytes] = Map([])
  for i in 0..<keys.length() {
    let value = if i == 0 { b"" } else { Bytes::make(256, i.to_byte()) }
    txn.put(keys[i], value)
    model[keys[i]] = value
  }
  keys.sort_by(cursor_order)
  let all = [ for key in keys => (key, model[key]) ]
  assert_eq(cursor_rows(txn.scan(b"")), all)
  for
    (start, end) in [
      (b"", b"a"),
      (b"a", b"z"),
      (b"a\x01", b"key-1030"),
      (b"key-1020", b"key-1080"),
      (b"z", b"z"),
    ] {
    let expected = all.filter(row => {
      cursor_order(row.0, start) >= 0 && cursor_order(row.0, end) < 0
    })
    assert_eq(cursor_rows(txn.scan(start, end~)), expected)
  }
  for
    prefix in [
      b"", b"a", b"a\xff", b"\x00\xff", b"\xff", b"\xff\xff", b"key-10",
    ] {
    let expected = all.filter(row => {
      row.0.length() >= prefix.length() && row.0[:prefix.length()] == prefix[:]
    })
    assert_eq(cursor_rows(txn.scan_prefix(prefix)), expected)
  }
  assert_eq(cursor_rows(txn.scan(b"\xff\xff\x01")), [])
  try txn.scan(b"z", end=b"a") catch {
    @vellum.DbError::InvalidRange => ()
    error => fail("\{error}")
  } noraise {
    _ => fail("inverted range accepted")
  }
  let owned_cursor = txn.scan(b"a", end=b"b")
  let owned = owned_cursor.next()
  ignore(owned_cursor.next())
  txn.commit()
  expect_cursor_error(owned_cursor, @vellum.DbError::TxnClosed)
  db.close()
  assert_eq(owned, Some((b"a", model[b"a"])))
  let db = @vellum.open(path)
  let txn = db.begin()
  assert_eq(cursor_rows(txn.scan_prefix(b"")), all)
  txn.abort()
  db.close()
  assert_eq(owned, Some((b"a", model[b"a"])))
}

///|
async test "every accepted write attempt invalidates cursors even EOF and fresh scans recover" {
  let dir = @fs.tmpdir(prefix="vellum-cursor-write")
  defer @fs.rmdir(dir, recursive=true)
  let db = @vellum.open("\{dir}/db")
  let txn = db.begin()
  txn.put(b"a", b"kept")
  for operation in 0..<5 {
    let first = txn.scan(b"")
    let second = txn.scan(b"z", end=b"z")
    assert_eq(second.next(), None)
    if operation == 0 {
      txn.put(b"a", b"kept")
    }
    if operation == 1 {
      assert_false(txn.delete(b"missing"))
    }
    if operation == 2 {
      try txn.put(b"a", Bytes::make(4001, b'x')) catch {
        @vellum.DbError::ValueTooLarge => ()
        error => fail("\{error}")
      } noraise {
        _ => fail("oversized value accepted")
      }
    }
    if operation == 3 {
      try txn.put(Bytes::make(4085, b'z'), b"") catch {
        @vellum.DbError::ValueTooLarge => ()
        error => fail("\{error}")
      } noraise {
        _ => fail("unrepresentable separator accepted")
      }
    }
    if operation == 4 {
      assert_true(txn.delete(b"a"))
      txn.put(b"a", b"kept")
    }
    expect_cursor_error(first, @vellum.DbError::CursorInvalidated)
    expect_cursor_error(second, @vellum.DbError::CursorInvalidated)
    assert_eq(cursor_rows(txn.scan(b"")), [(b"a", b"kept")])
  }
  let cursor = txn.scan(b"", end=b"")
  txn.abort()
  expect_cursor_error(cursor, @vellum.DbError::TxnClosed)
  try txn.scan(b"z", end=b"a") catch {
    @vellum.DbError::TxnClosed => ()
    error => fail("\{error}")
  } noraise {
    _ => fail("ended scan accepted")
  }
  let txn = db.begin()
  let cursor = txn.scan(b"")
  db.close()
  expect_cursor_error(cursor, @vellum.DbError::Closed)
}
