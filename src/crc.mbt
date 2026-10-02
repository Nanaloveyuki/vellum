///|
/// CRC-32/ISO-HDLC over a borrowed view; no buffer copies or accumulator objects.
fn crc32(bytes : BytesView) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for byte in bytes {
    crc = crc ^ byte.to_uint()
    for _ in 0..<8 {
      crc = if (crc & 1U) == 1U { (crc >> 1) ^ 0xEDB88320U } else { crc >> 1 }
    }
  }
  crc ^ 0xFFFFFFFFU
}
