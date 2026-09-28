///|
/// 页大小固定 4096 字节
pub let page_size : Int = 4096

///|
let magic : Bytes = b"VELLUM\x01\x00"

///|
let format_version : UInt = 1U

///|
/// 叶节点里 key 加 value 的上限。第一版不跨页
pub let max_value_len : Int = 4000

///|
let header_len : Int = 48
