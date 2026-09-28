///|
/// `open` 和事务操作失败时抛出这个错误，调用方按构造器分支。
pub(all) suberror DbError {
  /// `close` 之后还在使用这个库或事务。
  Closed
  /// `begin` 时上一个事务还没有 `commit` 或 `abort`。
  TxnOpen
  /// `value` 超过 `max_value_len`，或者 key 和 value 放不进一页。
  ValueTooLarge
  /// 页文件或 WAL 的 magic、版本、校验和或页结构不对。
  Corrupt
  /// 读或写文件失败。参数是底层错误文本。
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
