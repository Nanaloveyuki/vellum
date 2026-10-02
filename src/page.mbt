///|
priv struct Meta {
  root : Int
  freelist : Int
  txn_id : Int
  page_count : Int
}

///|
fn blank_page() -> FixedArray[Byte] {
  FixedArray::make(page_size, b'\x00')
}

///|
fn page_bytes(page : FixedArray[Byte]) -> Bytes {
  fixed_to_bytes(page)
}

///|
/// 第 0 页：magic、version、page_size、root、freelist、txn_id、page_count、crc32
fn encode_header(meta : Meta) -> FixedArray[Byte] {
  let page = blank_page()
  copy_bytes(magic, page, 0)
  write_u32(page, 8, format_version)
  write_u32(page, 12, page_size.reinterpret_as_uint())
  write_u64_int(page, 16, meta.root)
  write_u64_int(page, 24, meta.freelist)
  write_u64_int(page, 32, meta.txn_id)
  write_u64_int(page, 40, meta.page_count)
  write_u32(
    page,
    header_len,
    crc32(page.unsafe_reinterpret_as_bytes()[:header_len]),
  )
  page
}

///|
fn decode_header(page : Bytes) -> Meta raise DbError {
  guard page.length() == page_size else { raise DbError::Corrupt }
  guard page[0:8] == magic[:] else { raise DbError::Corrupt }
  guard read_u32(page, 8) == format_version else { raise DbError::Corrupt }
  guard read_u32(page, 12) == page_size.reinterpret_as_uint() else {
    raise DbError::Corrupt
  }
  let stored = read_u32(page, header_len)
  guard crc32(page[:header_len]) == stored else { raise DbError::Corrupt }
  {
    root: read_u64_as_int(page, 16),
    freelist: read_u64_as_int(page, 24),
    txn_id: read_u64_as_int(page, 32),
    page_count: read_u64_as_int(page, 40),
  }
}
