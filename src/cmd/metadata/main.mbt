///|
async fn demonstrate(path : String) -> Unit {
  let db = @vellum.open(path)
  let initial = [
    { path: "root.txt", size: 10L, mtime: 0L, },
    { path: "docs/a.txt", size: 11L, mtime: -1L, },
    { path: "docs/b.txt", size: 12L, mtime: -1L, },
    { path: "docs/nested/deep.txt", size: 13L, mtime: 1L, },
    { path: "minimum", size: 0L, mtime: -9223372036854775808L, },
    {
      path: "maximum",
      size: 9223372036854775807L,
      mtime: 9223372036854775807L,
    },
  ]
  for record in initial {
    upsert(db, record)
  }
  verify_all(db, initial)
  assert_eq(by_directory(db, "").map(record => record.path), [
    "maximum", "minimum", "root.txt",
  ])
  assert_eq(by_directory(db, "docs").map(record => record.path), [
    "docs/a.txt", "docs/b.txt",
  ])
  assert_eq(by_time(db).map(record => record.path), [
    "minimum", "docs/a.txt", "docs/b.txt", "root.txt", "docs/nested/deep.txt", "maximum",
  ])
  println(
    "initial: root=maximum,minimum,root.txt; docs direct=docs/a.txt,docs/b.txt; signed times=min,-1,-1,0,1,max",
  )
  let updated = { path: "docs/a.txt", size: 99L, mtime: 5L, }
  upsert(db, updated)
  rename_record(db, "docs/b.txt", "docs/renamed.txt")
  rename_record(db, "docs/renamed.txt", "docs/renamed.txt")
  assert_false(remove(db, "missing"))
  assert_true(remove(db, "root.txt"))
  try rename_record(db, "missing", "target") catch {
    MissingRecord => println("rename missing: MissingRecord")
    error => raise error
  } noraise {
    _ => fail("missing rename accepted")
  }
  try rename_record(db, "docs/a.txt", "docs/renamed.txt") catch {
    RenameConflict =>
      println("rename conflict: RenameConflict; target preserved")
    error => raise error
  } noraise {
    _ => fail("rename conflict accepted")
  }
  let expected = [
    updated,
    { path: "docs/renamed.txt", size: 12L, mtime: -1L, },
    initial[3],
    initial[4],
    initial[5],
  ]
  verify_all(db, expected)
  for
    malformed in [
      "", "/absolute", "C:/drive", "a\\b", "a\u0000b", "a//b", "a/", ".", "a/../b",
      "a/./b",
    ] {
    try upsert(db, { path: malformed, size: 1L, mtime: 0L, }) catch {
      InvalidPath => ()
      error => raise error
    } noraise {
      _ => fail("invalid path accepted")
    }
  }
  try upsert(db, { path: "negative", size: -1L, mtime: 0L, }) catch {
    InvalidSize => ()
    error => raise error
  } noraise {
    _ => fail("negative size accepted")
  }
  println(
    "input rejection: 10 malformed paths and negative size; no normalization",
  )
  let long_path = "d".repeat(2100) + "/leaf"
  try rename_record(db, "docs/a.txt", long_path) catch {
    @vellum.DbError::ValueTooLarge =>
      println(
        "rename capacity failure after primary/time writes: ValueTooLarge; entire logical transaction aborted",
      )
    error => raise error
  } noraise {
    _ => fail("oversized directory index accepted")
  }
  verify_all(db, expected)
  assert_eq(by_directory(db, "docs").map(record => record.path), [
    "docs/a.txt", "docs/renamed.txt",
  ])
  assert_eq(by_time(db).map(record => record.path), [
    "minimum", "docs/renamed.txt", "docs/nested/deep.txt", "docs/a.txt", "maximum",
  ])
  db.close()
  let db = @vellum.open(path)
  verify_all(db, expected)
  assert_eq(by_directory(db, "").map(record => record.path), [
    "maximum", "minimum",
  ])
  assert_eq(by_directory(db, "docs").map(record => record.path), [
    "docs/a.txt", "docs/renamed.txt",
  ])
  assert_eq(by_time(db).map(record => record.mtime), [
    -9223372036854775808L, -1L, 1L, 5L, 9223372036854775807L,
  ])
  db.close()
  println(
    "reopen: 5 primary records + 5 directory + 5 time entries exactly checked; upsert/delete/rename/abort consistent",
  )
}

///|
async fn main {
  let dir = @fs.tmpdir(prefix="vellum-metadata")
  defer @fs.rmdir(dir, recursive=true)
  demonstrate("\{dir}/metadata.db")
}
