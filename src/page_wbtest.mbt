///|
test "crc32 matches the iso-hdlc check value" {
  inspect(crc32(b"123456789"), content="3421780262")
}

///|
fn sample_meta() -> Meta {
  { root: 3, freelist: 7, txn_id: 11, page_count: 12, }
}

///|
test "header round trip keeps meta" {
  let decoded = decode_header(page_bytes(encode_header(sample_meta()))) catch {
    err => fail("\{err}")
  }
  inspect(decoded.root, content="3")
  inspect(decoded.freelist, content="7")
  inspect(decoded.txn_id, content="11")
  inspect(decoded.page_count, content="12")
}

///|
test "header rejects a flipped byte" {
  let page = encode_header(sample_meta())
  page[20] = page[20] ^ b'\x01'
  try decode_header(page_bytes(page)) catch {
    DbError::Corrupt => ()
    err => fail("\{err}")
  } noraise {
    _ => fail("expected corrupt header")
  }
}
