///|
fn byte_order(left : Bytes, right : Bytes) -> Int {
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
fn record_key(domain : String, index : Int) -> Bytes {
  @utf8.encode("\{domain}/\{1000000 + index}")
}

///|
fn record_value(key : Bytes) -> Bytes {
  Bytes::makei(32, i => key[i % key.length()])
}

///|
async fn range_rows(
  txn : @vellum.Txn,
  start : Bytes,
  end : Bytes,
) -> Array[(Bytes, Bytes)] {
  let cursor = txn.scan(start, end~)
  let result = []
  while cursor.next() is Some(row) {
    result.push(row)
  }
  result
}

///|
async fn enumerate_sort_rows(
  txn : @vellum.Txn,
  start : Bytes,
  end : Bytes,
) -> Array[(Bytes, Bytes)] {
  let cursor = txn.scan(b"")
  let all = []
  while cursor.next() is Some(row) {
    all.push(row)
  }
  all.sort_by((left, right) => byte_order(left.0, right.0))
  all.filter(row => byte_order(row.0, start) >= 0 && byte_order(row.0, end) < 0)
}

///|
async fn benchmark(dir : String, total : Int) -> Unit {
  let path = "\{dir}/scale-\{total}.db"
  let before = (total - 100) / 2
  let after = total - 100 - before
  let start = record_key("m-hit", 0)
  let end = record_key("m-hit", 100)
  let expected = [
    for i in 0..<100 => {
      let key = record_key("m-hit", i)
      (key, record_value(key))
    }
  ]
  let build_start = @async.now()
  let db = @vellum.open(path)
  let txn = db.begin()
  for
    (domain, count) in [
      ("a-before", before),
      ("m-hit", 100),
      ("z-after", after),
    ] {
    for i in 0..<count {
      let key = record_key(domain, i)
      txn.put(key, record_value(key))
    }
  }
  txn.commit()
  db.close()
  let build_ms = @async.now() - build_start
  let open_start = @async.now()
  let db = @vellum.open(path)
  let open_ms = @async.now() - open_start
  let txn = db.begin()
  {
    let all = txn.scan(b"")
    let mut count = 0
    while all.next() is Some((key, value)) {
      let domain = if count < before {
        "a-before"
      } else if count < before + 100 {
        "m-hit"
      } else {
        "z-after"
      }
      let index = if count < before {
        count
      } else if count < before + 100 {
        count - before
      } else {
        count - before - 100
      }
      assert_eq(key, record_key(domain, index))
      assert_eq(value, record_value(key))
      count += 1
    }
    assert_eq(count, total)
  }
  assert_eq(range_rows(txn, start, end), expected)
  assert_eq(enumerate_sort_rows(txn, start, end), expected)
  println(
    "scale total=\{total} before=\{before} hits=100 after=\{after} build_commit_close_ms=\{build_ms} full_image_open_ms=\{open_ms} verified_all=\{total}",
  )
  let cursor_repeats = 1000
  let baseline_repeats = 10
  for sample in 1..<=3 {
    let clock = @async.now()
    let mut seen = 0
    for _ in 0..<cursor_repeats {
      seen += range_rows(txn, start, end).length()
    }
    let cursor_ms = @async.now() - clock
    assert_eq(seen, cursor_repeats * 100)
    let clock = @async.now()
    let mut seen = 0
    for _ in 0..<baseline_repeats {
      seen += enumerate_sort_rows(txn, start, end).length()
    }
    let baseline_ms = @async.now() - clock
    assert_eq(seen, baseline_repeats * 100)
    assert_eq(range_rows(txn, start, end), expected)
    assert_eq(enumerate_sort_rows(txn, start, end), expected)
    println(
      "sample=\{sample} total=\{total} hits=100 cursor_repeats=\{cursor_repeats} cursor_total_ms=\{cursor_ms} cursor_avg_us=\{cursor_ms.to_double() * 1000.0 / cursor_repeats.to_double()} full_cursor_enumerate_sort_repeats=\{baseline_repeats} baseline_total_ms=\{baseline_ms} baseline_avg_us=\{baseline_ms.to_double() * 1000.0 / baseline_repeats.to_double()} exact_rows=ok",
    )
  }
  txn.abort()
  db.close()
}

///|
async fn main {
  let dir = @fs.tmpdir(prefix="vellum-scan-bench")
  defer @fs.rmdir(dir, recursive=true)
  println(
    "native; run with --release; milliseconds from monotonic async.now; 3 samples; fixed 100 owned rows; baseline=FULL public cursor enumerate+independent unsigned byte sort+filter (not point-get or MoonKV)",
  )
  for total in [1000, 10000, 100000] {
    benchmark(dir, total)
  }
  println(
    "correctness: every dataset row and every compared result byte checked outside timing; temporary databases will be removed on exit",
  )
}
