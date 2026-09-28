///|
/// 调用方可以匹配的失败
pub(all) suberror DbError {
  /// 库已经关闭
  Closed
  /// 已经有一个未结束的事务
  TxnOpen
  /// value 超过单页上限
  ValueTooLarge
  /// 页文件或 WAL 的 magic、版本或校验和不对
  Corrupt
  /// 文件读写失败
  Io(String)
} derive(Eq, Debug)

///|
pub extend DbError with Eq::{equal, not_equal}

///|
pub extend DbError with @debug.Debug::{to_repr}

///|
pub impl Show for DbError with fn output(self, logger) {
  logger.write_string(self.to_repr().to_string())
}

///|
pub extend DbError with Show::{output, to_string}
