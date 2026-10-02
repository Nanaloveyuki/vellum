///|
async fn main {
  let dir = @fs.tmpdir(prefix="vellum-bench")
  defer @fs.rmdir(dir, recursive=true)
  println("native release; elapsed milliseconds; temporary files; 3 samples")
  for n in [32, 128, 512] {
    let path = "\{dir}/bench-\{n}.db"
    let payload = Bytes::make(3000, b'x')
    let alternate = Bytes::make(3000, b'y')
    let db = @vellum.open(path)
    let fill_start = @async.now()
    let fill = db.begin()
    for i in 0..<n {
      fill.put(@utf8.encode("key-\{i}"), payload)
    }
    fill.commit()
    let fill_ms = @async.now() - fill_start
    let reads : Array[Int64] = []
    let unchanged : Array[Int64] = []
    let updates : Array[Int64] = []
    for sample in 0..<3 {
      let read_start = @async.now()
      for _ in 0..<200 {
        let read = db.begin()
        assert_eq(read.get(b"key-0"), Some(payload))
        read.abort()
      }
      reads.push(@async.now() - read_start)
      let same_start = @async.now()
      for _ in 0..<3 {
        let txn = db.begin()
        txn.put(b"key-0", payload)
        txn.commit()
      }
      unchanged.push(@async.now() - same_start)
      let update_start = @async.now()
      for turn in 0..<4 {
        let txn = db.begin()
        txn.put(b"key-0", if turn % 2 == 0 { alternate } else { payload })
        txn.commit()
      }
      updates.push(@async.now() - update_start)
      println(
        "keys=\{n} sample=\{sample + 1} read_200_ms=\{reads[sample]} unchanged_commit_3_ms=\{unchanged[sample]} update_commit_4_ms=\{updates[sample]}",
      )
    }
    db.close()
    let open_start = @async.now()
    let reopened = @vellum.open(path)
    let open_ms = @async.now() - open_start
    let read = reopened.begin()
    for i in 0..<n {
      assert_eq(read.get(@utf8.encode("key-\{i}")), Some(payload))
    }
    read.abort()
    reopened.close()
    println(
      "keys=\{n} bytes=\{@fs.file_size(path)} fill_ms=\{fill_ms} reopen_ms=\{open_ms}",
    )
  }
}
