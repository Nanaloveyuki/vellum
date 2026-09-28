///|
/// 每页字节数，固定 4096。
pub let page_size : Int = 4096

///|
let magic : Bytes = b"VELLUM\x01\x00"

///|
let format_version : UInt = 1U

///|
/// 单个 value 的字节上限。超过这个长度的 `put` 会抛 `DbError::ValueTooLarge`。
pub let max_value_len : Int = 4000

///|
let header_len : Int = 48
