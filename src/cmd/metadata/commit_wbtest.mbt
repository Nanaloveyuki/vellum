///|
async test "metadata commit IO failure preserves original error and requires reopen" {
  let dir = @fs.tmpdir(prefix="vellum-metadata-commit")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = @vellum.open(path)
  @fs.mkdir(path)
  let record = { path: "a", size: 1L, mtime: 0L, }
  try upsert(db, record) catch {
    @vellum.DbError::Io(_) => ()
    error => fail("original commit error was masked: \{error}")
  } noraise {
    _ => fail("checkpoint unexpectedly succeeded")
  }
  try db.begin() catch {
    @vellum.DbError::RecoveryRequired => ()
    error => fail("\{error}")
  } noraise {
    _ => fail("failed commit allowed new transaction")
  }
  db.close()
  @fs.rmdir(path)
  let db = @vellum.open(path)
  verify_all(db, [record])
  db.close()
}
