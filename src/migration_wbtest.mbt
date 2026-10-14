// Genuine writer fixtures: v0.3.0 commit 2574f5742f437dc41654f66b933eb737c4a4e7af.
// main.db SHA256 e9d2930666df23f19ee501a0a360bb1181b0aab54a8ca2a18861a387fbc0ca72.
// committed.wal SHA256 b2faef3b4d24c33b90abe888c22903c11084e0dbb8f0910a4c972664b24fc275.
// Expected rows are producer inputs, not decoded from the migration target.

///|
fn migration_fixture_rows(updated~ : Bool) -> Array[(Bytes, Bytes)] {
  let rows : Array[(Bytes, Bytes)] = [
    (b"", b""),
    (b"\x00", b"zero"),
    (b"\x00\xff", b"zero-ff"),
    (b"a", b"a"),
    (b"aa", if updated { b"updated-aa" } else { b"aa" }),
    (b"a\x00", b"a-zero"),
    (b"z", b"z"),
    (b"\x80", b"high"),
    (b"\xff", b"ff"),
    (b"\xff\x00\xff", b"ff-zero-ff"),
  ]
  for i in 0..<96 {
    rows.push(
      (
        @utf8.encode("fixture-\{1000 + i}"),
        Bytes::make(256, (i + (if updated { 1 } else { 0 })).to_byte()),
      ),
    )
  }
  rows
}

///|
async fn migration_fixture_verify(
  destination : String,
  updated~ : Bool,
) -> Unit {
  let db = open(destination)
  let txn = db.begin()
  for (key, value) in migration_fixture_rows(updated~) {
    assert_eq(txn.get(key), Some(value))
  }
  let cursor = txn.scan(b"")
  let mut count = 0
  while cursor.next() is Some(_) {
    count += 1
  }
  assert_eq(count, 106)
  txn.abort()
  db.close()
}

///|
async test "migrate genuine multi-page v1 and recoverable missing or torn main" {
  let dir = @fs.tmpdir(prefix="vellum-migration")
  defer @fs.rmdir(dir, recursive=true)
  let main = @fs.read_file("src/fixtures/legacy-v1/main.db").binary()
  let wal = @fs.read_file("src/fixtures/legacy-v1/committed.wal").binary()
  for variant in ["clean", "wal", "torn", "zero", "missing"] {
    let source = "\{dir}/\{variant}.db"
    let destination = "\{dir}/\{variant}-v2.db"
    let source_bytes = match variant {
      "zero" => b""
      "torn" => main[:main.length() - 1].to_owned()
      _ => main
    }
    if variant != "missing" {
      @fs.write_file(source, source_bytes, sync=@fs.Full)
    }
    if variant != "clean" {
      @fs.write_file(wal_path(source), wal, sync=@fs.Full)
    }
    migrate_v1(source, destination)
    if variant == "missing" {
      assert_false(@fs.exists(source))
    } else {
      assert_eq(@fs.read_file(source).binary(), source_bytes)
    }
    if variant != "clean" {
      assert_eq(@fs.read_file(wal_path(source)).binary(), wal)
    }
    assert_false(@fs.exists(wal_path(destination)))
    migration_fixture_verify(destination, updated=variant != "clean")
  }
}

///|
async test "migration rejects occupied destination source aliases and dangling links" {
  let dir = @fs.tmpdir(prefix="vellum-migration-reject")
  defer @fs.rmdir(dir, recursive=true)
  let source = "\{dir}/source.db"
  let destination = "\{dir}/converted.db"
  let source_bytes = @fs.read_file("src/fixtures/legacy-v1/main.db").binary()
  @fs.write_file(source, source_bytes, sync=@fs.Full)
  for path in [destination, wal_path(destination)] {
    @fs.symlink(target="missing", path)
    try migrate_v1(source, destination) catch {
      DbError::Io(_) => ()
      err => fail("wrong occupied-target error: \{err}")
    } noraise {
      _ => fail("dangling target entry accepted")
    }
    @fs.remove(path)
  }
  try migrate_v1(source, source) catch {
    DbError::Io(_) => ()
    err => fail("wrong alias error: \{err}")
  } noraise {
    _ => fail("source alias accepted")
  }
  let linked_source = "\{dir}/alias.db"
  @fs.symlink(target=source, linked_source)
  try migrate_v1(linked_source, destination) catch {
    DbError::Io(_) => ()
    err => fail("wrong symlink-source error: \{err}")
  } noraise {
    _ => fail("source symlink accepted")
  }
  @fs.symlink(target="missing", wal_path(source))
  try migrate_v1(source, destination) catch {
    DbError::Io(_) => ()
    err => fail("wrong symlink-WAL error: \{err}")
  } noraise {
    _ => fail("source WAL symlink accepted")
  }
  assert_eq(@fs.read_file(source).binary(), source_bytes)
  assert_false(@fs.exists(destination))
}

///|
async test "migration persists empty v2 and rejects missing source or corrupt complete WAL" {
  let dir = @fs.tmpdir(prefix="vellum-migration-empty")
  defer @fs.rmdir(dir, recursive=true)
  let source = "\{dir}/source.db"
  let destination = "\{dir}/v2.db"
  try migrate_v1(source, destination) catch {
    DbError::Corrupt => ()
    err => fail("wrong missing-source error: \{err}")
  } noraise {
    _ => fail("missing source accepted")
  }
  let source_bytes = @fs.read_file("src/fixtures/legacy-v1/empty.db").binary()
  @fs.write_file(source, source_bytes, sync=@fs.Full)
  migrate_v1(source, destination)
  let db = open(destination)
  let txn = db.begin()
  assert_eq(txn.get(b"missing"), None)
  txn.abort()
  db.close()
  assert_true(@fs.file_size(destination) >= page_size.to_int64())
  let corrupt = Bytes::make(20, 0)
  @fs.write_file(wal_path(source), corrupt, sync=@fs.Full)
  try migrate_v1(source, "\{dir}/bad.db") catch {
    DbError::Corrupt => ()
    err => fail("wrong corrupt-WAL error: \{err}")
  } noraise {
    _ => fail("corrupt complete WAL accepted")
  }
  assert_eq(@fs.read_file(source).binary(), source_bytes)
  assert_eq(@fs.read_file(wal_path(source)).binary(), corrupt)
}

///|
async test "migration cancellation race preserves source and never publishes a partial target" {
  let dir = @fs.tmpdir(prefix="vellum-migration-cancel")
  defer @fs.rmdir(dir, recursive=true)
  let source = "\{dir}/source.db"
  let destination = "\{dir}/v2.db"
  let source_bytes = @fs.read_file("src/fixtures/legacy-v1/main.db").binary()
  @fs.write_file(source, source_bytes, sync=@fs.Full)
  let mut finished = false
  @async.with_task_group(async fn(group) {
    let job = group.spawn(async fn() {
      defer {
        finished = true
      }
      migrate_v1(source, destination)
    })
    while !finished {
      let files = @fs.readdir(dir)
      if files.any(name => name.contains("vellum-migrate-")) {
        break
      }
      @async.pause()
    }
    job.cancel()
    try job.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => fail("wrong cancellation result: \{err}")
    } noraise {
      _ => ()
    }
  })
  assert_eq(@fs.read_file(source).binary(), source_bytes)
  assert_false(@fs.exists(wal_path(source)))
  if @fs.exists(destination) {
    migration_fixture_verify(destination, updated=false)
  }
  assert_false(@fs.exists(wal_path(destination)))
}
