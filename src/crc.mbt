///|
/// CRC-32/ISO-HDLC。多项式 0xEDB88320，初值全 1，结果取反
fn crc32(bytes : Bytes) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for i in 0..<bytes.length() {
    crc = crc ^ bytes[i].to_uint()
    for _ in 0..<8 {
      if (crc & 1U) == 1U {
        crc = (crc >> 1) ^ 0xEDB88320U
      } else {
        crc = crc >> 1
      }
    }
  }
  crc ^ 0xFFFFFFFFU
}
