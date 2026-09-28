///|
test "replay keeps committed pages and drops a torn tail" {
  let wal = Wal::new()
  let page = page_bytes(
    encode_header({ root: 1, freelist: 0, txn_id: 1, page_count: 2, }),
  )
  wal.append(Data(txn_id=1, page_id=0, page~))
  wal.append(Commit(txn_id=1))
  let torn = wal.bytes + b"\x01\x02"
  wal.bytes = torn
  let replayed = wal.replay() catch { err => fail("\{err}") }
  inspect(replayed.length(), content="1")
  assert_eq(replayed[0], page)
}

///|
test "uncommitted frames stay invisible" {
  let wal = Wal::new()
  wal.append(Data(txn_id=2, page_id=1, page=page_bytes(blank_page())))
  let replayed = wal.replay() catch { err => fail("\{err}") }
  inspect(replayed.length(), content="0")
}

///|
test "a bad checksum drops that frame and everything after it" {
  let wal = Wal::new()
  wal.append(Data(txn_id=3, page_id=1, page=page_bytes(blank_page())))
  wal.append(Commit(txn_id=3))
  let buf = wal.bytes.to_fixedarray()
  buf[16] = buf[16] ^ b'\xff'
  wal.bytes = fixed_to_bytes(buf)
  let replayed = wal.replay() catch { err => fail("\{err}") }
  inspect(replayed.length(), content="0")
}

///|
test "truncate clears replayed frames" {
  let wal = Wal::new()
  wal.append(Commit(txn_id=1))
  wal.truncate()
  let replayed = wal.replay() catch { err => fail("\{err}") }
  inspect(replayed.length(), content="0")
  inspect(wal.bytes.length(), content="0")
}
