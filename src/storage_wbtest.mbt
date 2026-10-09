///|
async test "checkpoint changes only supplied pages and preserves sparse gaps" {
  let dir = @fs.tmpdir(prefix="vellum-sparse-checkpoint")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let original = Bytes::make(64 * page_size, b'u')
  write_synced_bytes(path, original)
  let pages : Map[Int, Bytes] = Map([])
  pages[0] = Bytes::make(page_size, b'h')
  for i in 0..<20 {
    pages[2 * i + 1] = Bytes::make(page_size, i.to_byte())
  }
  write_page_batch(path, pages)
  let raw = read_all_bytes(path)
  assert_eq(raw.length(), original.length())
  for id in 0..<64 {
    assert_eq(
      raw[id * page_size:(id + 1) * page_size],
      pages.get(id).unwrap_or(Bytes::make(page_size, b'u'))[:],
    )
  }
}

///|
async test "cancelled page batch joins workers before the file can be overwritten" {
  let dir = @fs.tmpdir(prefix="vellum-cancel-checkpoint")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let pages : Map[Int, Bytes] = Map([])
  for id in 0..<4096 {
    pages[id] = Bytes::make(page_size, b'x')
  }
  @async.with_task_group(async fn(group) {
    let writer = group.spawn(async fn() { write_page_batch(path, pages) })
    while !@fs.exists(path) {
      @async.pause()
    }
    while @fs.file_size(path) == 0L {
      @async.pause()
    }
    writer.cancel()
    try writer.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => fail("\{err}")
    } noraise {
      _ => fail("cancelled page batch completed")
    }
  })
  // Any still-running pwrite would race this replacement or regrow the file.
  write_synced_bytes(path, b"replacement")
  @async.sleep(20)
  assert_eq(read_all_bytes(path), b"replacement")
}

///|
async test "failed parallel checkpoint retains complete redo for recovery" {
  if !(@async.platform is Linux) {
    return
  }
  let dir = @fs.tmpdir(prefix="vellum-parallel-failure")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let db = open(path)
  let txn = db.begin()
  for i in 0..<32 {
    txn.put(@utf8.encode("key-\{i}"), Bytes::make(3000, i.to_byte()))
  }
  @fs.symlink(target="/dev/full", path)
  try txn.commit() catch {
    DbError::Io(_) => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("invalid checkpoint device accepted")
  }
  try txn.get(b"key-0") catch {
    DbError::RecoveryRequired => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("failed checkpoint remained usable")
  }
  db.close()
  @fs.remove(path)
  let db = open(path)
  let read = db.begin()
  for i in 0..<32 {
    assert_eq(
      read.get(@utf8.encode("key-\{i}")),
      Some(Bytes::make(3000, i.to_byte())),
    )
  }
  read.abort()
  db.close()
}
