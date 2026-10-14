///|
// Exact v0.3.0 writer output (2574f5742f437dc41654f66b933eb737c4a4e7af),
// create/commit/delete/commit: SHA256 3b82072d5f77f314cc07d3bbf71b38c933a28ad76025f48222509b01085d3690.
fn genuine_empty_v1() -> Bytes {
  let image = FixedArray::make(2 * page_size, b'\x00')
  let header = b"VELLUM\x01\x00\x01\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x50\xd1\xe3\x63"
  copy_bytes(header, image, 0)
  image[page_size] = kind_free
  fixed_to_bytes(image)
}

///|
// A small wire fixture isolates shortlex-versus-lexical validation; it is not a v1 writer.
fn shortlex_v1_pages() -> Array[Bytes] raise DbError {
  let header = encode_header({ root: 1, freelist: 0, txn_id: 1, page_count: 2, })
  write_u32(header, 8, 1U)
  write_u32(header, header_len, crc32(page_bytes(header)[:header_len]))
  let leaf = encode_leaf({
    entries: [
      { key: b"", value: b"", },
      { key: b"\x00", value: b"zero", },
      { key: b"z", value: b"short", },
      { key: b"\xff", value: b"high", },
      { key: b"aa", value: b"long", },
    ],
    right: 0,
  })
  [page_bytes(header), page_bytes(leaf)]
}

///|
fn legacy_test_image(pages : Array[Bytes]) -> Bytes {
  let image = FixedArray::make(pages.length() * page_size, b'\x00')
  for i in 0..<pages.length() {
    copy_bytes(pages[i], image, i * page_size)
  }
  fixed_to_bytes(image)
}

///|
async test "genuine empty v1 refusal preserves source and does not create WAL" {
  let dir = @fs.tmpdir(prefix="vellum-legacy-empty")
  defer @fs.rmdir(dir, recursive=true)
  let path = "\{dir}/db"
  let original = genuine_empty_v1()
  write_synced_bytes(path, original)
  try open(path) catch {
    DbError::UnsupportedFormat => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("legacy image accepted")
  }
  assert_eq(read_all_bytes(path), original)
  assert_eq(@fs.exists(wal_path(path)), false)
}

///|
async test "shortlex v1 refusal validates committed overlay before damaged main" {
  let pages = shortlex_v1_pages()
  let complete = legacy_test_image(pages)
  for torn_main in [false, true] {
    let dir = @fs.tmpdir(prefix="vellum-legacy-overlay")
    defer @fs.rmdir(dir, recursive=true)
    let path = "\{dir}/db"
    let original = if torn_main { b"damaged" } else { complete }
    write_synced_bytes(path, original)
    let wal = encode_wal([
      Data(txn_id=1, page_id=0, page=pages[0]),
      Data(txn_id=1, page_id=1, page=pages[1]),
      Commit(txn_id=1),
    ])
    write_synced_bytes(wal_path(path), wal)
    try open(path) catch {
      DbError::UnsupportedFormat => ()
      err => fail("\{err}")
    } noraise {
      _ => fail("legacy overlay accepted")
    }
    assert_eq(read_all_bytes(path), original)
    assert_eq(read_all_bytes(wal_path(path)), wal)
  }
}

///|
async test "corrupt legacy CRC graph and complete WAL beat unsupported format" {
  let pages = shortlex_v1_pages()
  for fault in 0..<3 {
    let dir = @fs.tmpdir(prefix="vellum-legacy-corrupt")
    defer @fs.rmdir(dir, recursive=true)
    let path = "\{dir}/db"
    let image = FixedArray::make(2 * page_size, b'\x00')
    for i in 0..<pages.length() {
      copy_bytes(pages[i], image, i * page_size)
    }
    if fault == 0 {
      image[header_len] = image[header_len] ^ b'\x01'
    } else if fault == 1 {
      write_u32(image, page_size + 3, 1U)
    }
    let original = fixed_to_bytes(image)
    write_synced_bytes(path, original)
    let wal = if fault == 2 {
      let encoded = encode_wal([Commit(txn_id=1)])
      let broken = FixedArray::make(encoded.length(), b'\x00')
      copy_bytes(encoded, broken, 0)
      broken[broken.length() - 1] = broken[broken.length() - 1] ^ b'\x01'
      fixed_to_bytes(broken)
    } else {
      b""
    }
    write_synced_bytes(wal_path(path), wal)
    try open(path) catch {
      DbError::Corrupt => ()
      err => fail("\{err}")
    } noraise {
      _ => fail("corrupt legacy image accepted")
    }
    assert_eq(read_all_bytes(path), original)
    assert_eq(read_all_bytes(wal_path(path)), wal)
  }
}

///|
test "v1 and v2 validation reject unaccounted allocated pages" {
  let pages = shortlex_v1_pages()
  let header = FixedArray::make(page_size, b'\x00')
  copy_bytes(pages[0], header, 0)
  write_u64_int(header, 40, 3)
  write_u32(header, header_len, crc32(page_bytes(header)[:header_len]))
  let orphan = page_bytes(encode_free(0))
  let image = legacy_test_image([page_bytes(header), pages[1], orphan])
  try legacy_read_image(image, Map([])) catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("orphan legacy page accepted")
  }
  let tree = Tree::new()
  tree.pages[1] = orphan
  tree.next_page = 2
  try tree.validate() catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("orphan v2 page accepted")
  }
}
