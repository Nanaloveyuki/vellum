///|
let crc32_table : FixedArray[UInt] = {
  let table = FixedArray::make(256, 0U)
  for i in 0..<256 {
    let mut crc = i.reinterpret_as_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) == 1U { (crc >> 1) ^ 0xEDB88320U } else { crc >> 1 }
    }
    table[i] = crc
  }
  table
}

///|
/// CRC-32/ISO-HDLC; same v1 checksum, one table lookup per byte.
fn crc32(bytes : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for byte in bytes {
    let index = ((crc ^ byte.to_uint()) & 0xFFU).reinterpret_as_int()
    crc = (crc >> 8) ^ crc32_table[index]
  }
  crc ^ 0xFFFFFFFFU
}
