///|
/// 每页字节数，固定 4096。
pub let page_size : Int = 4096

///|
let magic : Bytes = b"VELLUM\x01\x00"

///|
let format_version : UInt = 2U

///|
fn header_version(page : Bytes) -> UInt raise DbError {
  guard page.length() == page_size else { raise DbError::Corrupt }
  guard page[0:8] == magic[:] else { raise DbError::Corrupt }
  guard read_u32(page, 12) == page_size.reinterpret_as_uint() else {
    raise DbError::Corrupt
  }
  guard crc32(page[:header_len]) == read_u32(page, header_len) else {
    raise DbError::Corrupt
  }
  read_u32(page, 8)
}

///|
/// 单个 value 的字节上限。超过这个长度的 `put` 会抛 `DbError::ValueTooLarge`。
pub let max_value_len : Int = 4000

///|
let header_len : Int = 48
