///|
fn bench_key(i : Int) -> Bytes {
  @utf8.encode("key-\{1000000 + i}")
}

///|
async fn bench_workload(dir : String, value_len : Int) -> Unit {
  let keys = [ for i in 0..<4096 => bench_key(i) ]
  let payload = Bytes::make(value_len, b'x')
  let alternate = Bytes::make(value_len, b'y')
  for sample in 1..<=3 {
    let path = "\{dir}/work-\{value_len}-\{sample}.db"
    let db = @vellum.open(path)
    let fill = db.begin()
    let start = @async.now()
    for key in keys {
      fill.put(key, payload)
    }
    let put_ms = @async.now() - start
    let start = @async.now()
    fill.commit()
    println(
      "fill value_len=\{value_len} sample=\{sample} keys=4096 put_ms=\{put_ms} commit_ms=\{@async.now() - start} bytes=\{@fs.file_size(path)}",
    )
    let txn = db.begin()
    let start = @async.now()
    let mut read_bytes = 0
    for _ in 0..<50000 {
      if txn.get(keys[0]) is Some(value) {
        read_bytes += value.length()
      }
    }
    assert_eq(read_bytes, 50000 * value_len)
    let hot_ms = @async.now() - start
    let start = @async.now()
    let mut read_bytes = 0
    for i in 0..<50000 {
      if txn.get(keys[i * 4051 % keys.length()]) is Some(value) {
        read_bytes += value.length()
      }
    }
    assert_eq(read_bytes, 50000 * value_len)
    let random_ms = @async.now() - start
    let absent = bench_key(keys.length() + 1)
    let start = @async.now()
    for _ in 0..<50000 {
      assert_eq(txn.get(absent), None)
    }
    println(
      "read value_len=\{value_len} sample=\{sample} count=50000 hot_ms=\{hot_ms} random_ms=\{random_ms} miss_ms=\{@async.now() - start}",
    )
    txn.abort()
    let txn = db.begin()
    let start = @async.now()
    for _ in 0..<10000 {
      txn.put(keys[0], payload)
    }
    let same_ms = @async.now() - start
    txn.commit()
    let txn = db.begin()
    let start = @async.now()
    for i in 0..<10000 {
      txn.put(keys[0], if i % 2 == 0 { alternate } else { payload })
    }
    let changed_ms = @async.now() - start
    txn.abort()
    println(
      "put value_len=\{value_len} sample=\{sample} count=10000 same_ms=\{same_ms} changed_ms=\{changed_ms}",
    )
    let txn = db.begin()
    let start = @async.now()
    for i in 0..<10000 {
      txn.put(
        keys[i * 4051 % keys.length()],
        if i % 2 == 0 {
          alternate
        } else {
          payload
        },
      )
    }
    let random_put_ms = @async.now() - start
    txn.abort()
    println(
      "random_put value_len=\{value_len} sample=\{sample} count=10000 elapsed_ms=\{random_put_ms}",
    )
    for batch in [1, 16, 64, 256] {
      let start = @async.now()
      for offset = 0; offset < 256; offset = offset + batch {
        let txn = db.begin()
        for i in offset..<(offset + batch) {
          txn.put(keys[i], alternate)
        }
        txn.commit()
      }
      println(
        "batch value_len=\{value_len} sample=\{sample} updates=256 batch=\{batch} elapsed_ms=\{@async.now() - start}",
      )
      let txn = db.begin()
      for i in 0..<256 {
        assert_eq(txn.get(keys[i]), Some(alternate))
        txn.put(keys[i], payload)
      }
      txn.commit()
    }
    db.close()
    let start = @async.now()
    let db = @vellum.open(path)
    let open_ms = @async.now() - start
    let txn = db.begin()
    for key in keys {
      assert_eq(txn.get(key), Some(payload))
    }
    txn.abort()
    db.close()
    println(
      "reopen value_len=\{value_len} sample=\{sample} elapsed_ms=\{open_ms} verified_keys=4096",
    )
  }
}

///|
async fn bench_fairness(dir : String, chunk : Int, sample : Int) -> Unit {
  let db = @vellum.open("\{dir}/fair-\{chunk}-\{sample}.db")
  let keys = [ for i in 0..<20000 => bench_key(i) ]
  let payload = Bytes::make(64, b'x')
  let mut finished = false
  let mut max_gap = 0L
  let mut ticks = 0
  @async.with_task_group(fn(group) {
    group.spawn_bg(async fn() {
      while !finished {
        let start = @async.now()
        @async.sleep(1)
        max_gap = max_gap.max(@async.now() - start)
        ticks += 1
      }
    })
    group.spawn_bg(async fn() {
      @async.sleep(2)
      let txn = db.begin()
      let start = @async.now()
      for i in 0..<keys.length() {
        txn.put(keys[i], payload)
        if chunk > 0 && (i + 1) % chunk == 0 {
          @async.pause()
        }
      }
      let put_ms = @async.now() - start
      txn.abort()
      finished = true
      println(
        "fairness sample=\{sample} puts=20000 pause_every=\{chunk} put_ms=\{put_ms}",
      )
    })
  })
  println(
    "heartbeat sample=\{sample} pause_every=\{chunk} max_gap_ms=\{max_gap} ticks=\{ticks}",
  )
  db.close()
}

///|
async fn main {
  let dir = @fs.tmpdir(prefix="vellum-bench")
  defer @fs.rmdir(dir, recursive=true)
  println(
    "native release; milliseconds; 3 samples; temporary files; reopen and values checked",
  )
  bench_workload(dir, 32)
  bench_workload(dir, 3000)
  for sample in 1..<=3 {
    bench_fairness(dir, 0, sample)
    bench_fairness(dir, 128, sample)
  }
}
