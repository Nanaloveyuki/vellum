///|
async test "metadata identity direct directory and signed time survive logical failures" {
  let dir = @fs.tmpdir(prefix="vellum-metadata-test")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = @vellum.open(path)
  let records = [
    { path: "a", size: 0L, mtime: -9223372036854775808L, },
    { path: "aa", size: 1L, mtime: 0L, },
    { path: "z", size: 2L, mtime: 0L, },
    { path: "é", size: 3L, mtime: 9223372036854775807L, },
    { path: "docs/a", size: 4L, mtime: -1L, },
    { path: "docs/nested/a", size: 5L, mtime: 1L, },
  ]
  for record in records {
    upsert(db, record)
  }
  assert_eq(by_directory(db, "").map(record => record.path), [
    "a", "aa", "z", "é",
  ])
  assert_eq(by_directory(db, "docs").map(record => record.path), ["docs/a"])
  assert_eq(by_time(db).map(record => record.path), [
    "a", "docs/a", "aa", "z", "docs/nested/a", "é",
  ])
  let colon = { path: "notes:a", size: 7L, mtime: 0L, }
  upsert(db, colon)
  assert_true(by_directory(db, "").contains(colon))
  assert_true(remove(db, colon.path))
  let case_record = { path: "A", size: 8L, mtime: 0L, }
  upsert(db, case_record)
  assert_true(by_directory(db, "").contains(case_record))
  assert_true(remove(db, case_record.path))
  for
    bad in [
      "", "/a", "C:a", "a\\b", "a\u0000b", "a//b", "a/", "./a", "a/../b", "a/.",
    ] {
    try upsert(db, { path: bad, size: 1L, mtime: 0L, }) catch {
      InvalidPath => ()
      error => raise error
    } noraise {
      _ => fail("malformed path accepted")
    }
  }
  try by_directory(db, "docs/") catch {
    InvalidPath => ()
    error => raise error
  } noraise {
    _ => fail("malformed directory accepted")
  }
  try upsert(db, { path: "negative", size: -1L, mtime: 0L, }) catch {
    InvalidSize => ()
    error => raise error
  } noraise {
    _ => fail("negative size accepted")
  }
  try rename_record(db, "absent", "absent") catch {
    MissingRecord => ()
    error => raise error
  } noraise {
    _ => fail("missing same-path rename accepted")
  }
  try rename_record(db, "a", "aa") catch {
    RenameConflict => ()
    error => raise error
  } noraise {
    _ => fail("rename overwrote existing identity")
  }
  rename_record(db, "a", "a")
  assert_false(remove(db, "absent"))
  verify_all(db, records)
  let long_path = "q".repeat(2100) + "/leaf"
  try rename_record(db, "a", long_path) catch {
    @vellum.DbError::ValueTooLarge => ()
    error => raise error
  } noraise {
    _ => fail("over-capacity index accepted")
  }
  db.close()
  let db = @vellum.open(path)
  verify_all(db, records)
  let changed = { path: "docs/a", size: 99L, mtime: 2L, }
  upsert(db, changed)
  rename_record(db, "aa", "docs/aa")
  assert_true(remove(db, "z"))
  let expected = [
    records[0],
    records[3],
    changed,
    records[5],
    { path: "docs/aa", size: 1L, mtime: 0L, },
  ]
  verify_all(db, expected)
  assert_eq(by_time(db).map(record => record.path), [
    "a", "docs/aa", "docs/nested/a", "docs/a", "é",
  ])
  assert_eq(by_directory(db, "docs").map(record => record.path), [
    "docs/a", "docs/aa",
  ])
  db.close()
  let db = @vellum.open(path)
  verify_all(db, expected)
  db.close()
}
