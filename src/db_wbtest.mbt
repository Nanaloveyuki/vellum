///|
async test "half a committed wal frame is replayed from the intact prefix" {
  let dir = @fs.tmpdir(prefix="vellum-tear")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/vellum.db"
  let db = open(path)
  let first = db.begin()
  first.put(b"kept", b"yes")
  first.commit()
  let second = db.begin()
  second.put(b"late", b"no")
  second.commit_until(pause_after_wal=true)
  let wal = wal_path(path)
  let full = read_all_bytes(wal)
  let torn = full[0:full.length() / 2].to_owned()
  write_synced_bytes(wal, torn)
  db.closed = true
  let reopened = open(path)
  let read = reopened.begin()
  assert_eq(read.get(b"kept"), Some(b"yes"))
  assert_true(read.get(b"late") is None)
  read.abort()
  reopened.close()
}
