///|
fn wal_page(mark : Byte) -> Bytes {
  let buf = FixedArray::make(page_size, mark)
  Bytes::from_array(buf[:])
}

///|
fn wal_must_corrupt(wal : Bytes) -> Unit raise {
  try replay_wal(wal) catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("corrupt WAL accepted")
  }
}

///|
test "replay_wal keeps a committed transaction and ignores an incomplete tail" {
  let page = wal_page(b'\x11')
  let wal = encode_wal([Data(txn_id=1, page_id=0, page~), Commit(txn_id=1)]) +
    b"\x01\x02"
  let replayed = replay_wal(wal)
  inspect(replayed.length(), content="1")
  assert_eq(replayed[0], page)
}

///|
test "replay_wal excludes transactions that never committed" {
  let wal = encode_wal([Data(txn_id=2, page_id=1, page=wal_page(b'\x22'))])
  assert_eq(replay_wal(wal), Map([]))
}

///|
test "replay_wal rejects a complete frame with a corrupted checksum" {
  let wal = encode_wal([Data(txn_id=3, page_id=1, page=wal_page(b'\x33'))])
  let buf = wal.to_fixedarray()
  buf[16] = buf[16] ^ b'\xff'
  wal_must_corrupt(Bytes::from_array(buf[:]))
}

///|
test "replay_wal rejects a commit frame with a corrupted checksum" {
  let wal = encode_wal([Commit(txn_id=4)])
  let buf = wal.to_fixedarray()
  buf[buf.length() - 1] = buf[buf.length() - 1] ^ b'\xff'
  wal_must_corrupt(Bytes::from_array(buf[:]))
}

///|
test "replay_wal rejects an unknown frame kind" {
  let wal = encode_wal([Data(txn_id=5, page_id=1, page=wal_page(b'\x55'))])
  let buf = wal.to_fixedarray()
  write_u32(buf, 0, 7U)
  wal_must_corrupt(Bytes::from_array(buf[:]))
}

///|
test "replay_wal ignores an incomplete frame shorter than its header" {
  let wal = encode_wal([Commit(txn_id=6)])
  assert_eq(replay_wal(wal[0:19].to_owned()), Map([]))
}

///|
test "replay_wal lets the last committed write to a page win" {
  let first = wal_page(b'\xaa')
  let second = wal_page(b'\xbb')
  let wal = encode_wal([
    Data(txn_id=7, page_id=2, page=first),
    Commit(txn_id=7),
    Data(txn_id=8, page_id=2, page=second),
    Commit(txn_id=8),
  ])
  let replayed = replay_wal(wal)
  inspect(replayed.length(), content="1")
  assert_eq(replayed[2], second)
}

///|
test "replay_wal keeps transactions that are interleaved before commit" {
  let a = wal_page(b'\xa1')
  let b = wal_page(b'\xb1')
  let wal = encode_wal([
    Data(txn_id=9, page_id=1, page=a),
    Data(txn_id=10, page_id=2, page=b),
    Commit(txn_id=10),
    Commit(txn_id=9),
  ])
  let replayed = replay_wal(wal)
  inspect(replayed.length(), content="2")
  assert_eq(replayed[1], a)
  assert_eq(replayed[2], b)
}

///|
test "replay_wal reads the older Data and Commit wire without a header page" {
  let kept = wal_page(b'\x77')
  let wal = encode_wal([
    Data(txn_id=11, page_id=1, page=kept),
    Commit(txn_id=11),
  ])
  assert_eq(replay_wal(wal)[1], kept)
}
