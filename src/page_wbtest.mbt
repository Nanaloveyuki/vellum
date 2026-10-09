///|
test "crc32 matches the iso-hdlc check value" {
  inspect(crc32(b"123456789"[:]), content="3421780262")
}

///|
fn reference_crc32(bytes : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for byte in bytes {
    crc = crc ^ byte.to_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) == 1U { (crc >> 1) ^ 0xEDB88320U } else { crc >> 1 }
    }
  }
  crc ^ 0xFFFFFFFFU
}

///|
test "crc32 matches independent bitwise oracle on offset and boundary slices" {
  for seed in [20261009U, 424242U, 8675309U] {
    let mut random = seed
    for length in [0, 1, 7, 255, 256, 4095, 4096, 4112, 65536] {
      let data = FixedArray::make(length + 13, b'\x00')
      for i in 0..<data.length() {
        random = random * 1664525U + 1013904223U
        data[i] = (random >> 24).to_byte()
      }
      let bytes = Bytes::from_array(data[:])
      for offset in [0, 1, 5, 13] {
        let view = bytes[offset:offset + length]
        assert_eq(crc32(view), reference_crc32(view))
      }
    }
  }
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
