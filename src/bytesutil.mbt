///|
fn read_u32(bytes : Bytes, index : Int) -> UInt raise DbError {
  guard index >= 0 && index + 4 <= bytes.length() else {
    raise DbError::Corrupt
  }
  bytes.unsafe_read_uint32_le(index)
}

///|
fn read_u16(bytes : Bytes, index : Int) -> Int raise DbError {
  guard index >= 0 && index + 2 <= bytes.length() else {
    raise DbError::Corrupt
  }
  bytes.unsafe_read_uint16_le(index).to_int()
}

///|
fn read_u64_as_int(bytes : Bytes, index : Int) -> Int raise DbError {
  guard index >= 0 && index + 8 <= bytes.length() else {
    raise DbError::Corrupt
  }
  let value = bytes.unsafe_read_uint64_le(index)
  guard value <= 0x7FFFFFFFUL else { raise DbError::Corrupt }
  value.reinterpret_as_int64().to_int()
}

///|
fn write_u32(buf : FixedArray[Byte], index : Int, value : UInt) -> Unit {
  buf.unsafe_write_uint32_le(index, value)
}

///|
fn write_u16(buf : FixedArray[Byte], index : Int, value : Int) -> Unit {
  buf.unsafe_write_uint16_le(index, value.reinterpret_as_uint().to_uint16())
}

///|
fn write_u64_int(buf : FixedArray[Byte], index : Int, value : Int) -> Unit {
  buf.unsafe_write_uint64_le(index, value.to_uint64())
}

///|
fn copy_bytes(src : Bytes, dst : FixedArray[Byte], dst_index : Int) -> Unit {
  dst.blit_from_bytes(dst_index, src, 0, src.length())
}

///|
fn owned_bytes(view : BytesView) -> Bytes {
  view.to_owned()
}

///|
fn fixed_to_bytes(buf : FixedArray[Byte]) -> Bytes {
  Bytes::from_array(buf)
}

///|
fn compare_bytes_view(left : BytesView, right : BytesView) -> Int {
  let shared = left.length().min(right.length())
  for i in 0..<shared {
    let difference = left[i].to_int() - right[i].to_int()
    if difference != 0 {
      return difference
    }
  }
  left.length() - right.length()
}
