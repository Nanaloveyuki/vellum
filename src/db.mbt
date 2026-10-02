///|
/// 打开的页库。一个路径对应一个文件，同时只能有一个事务。
pub struct Db {
  priv path : String
  priv tree : Tree
  priv mut txn_id : Int
  priv mut txn : Txn?
  priv mut closed : Bool
  priv mut recovery_required : Bool
}

///|
/// 当前这一次读写。`commit` 之后别的 `open` 才能看见；`abort` 则回到上次提交。
pub struct Txn {
  priv db : Db
  priv base_root : Int
  priv base_freelist : Int
  priv base_next : Int
  priv mut state : TxnState
}

///|
priv enum TxnState {
  Active
  Committing
  Ended
  Failed
}

///|
fn io_error(err : Error) -> DbError {
  DbError::Io(err.to_string())
}

///|
async fn read_all_bytes(path : String) -> Bytes raise DbError {
  let present = @fs.exists(path) catch { err => raise io_error(err) }
  if present {
    let data = @fs.read_file(path) catch { err => raise io_error(err) }
    data.binary()
  } else {
    b""
  }
}

///|
fn wal_path(path : String) -> String {
  "\{path}.wal"
}

///|
/// 打开并载入 `path`；新库在首次有修改的提交时创建文件。
/// 完整已提交 WAL 覆盖对应页后再验证；缺失且未被日志覆盖的页抛 `Corrupt`。
pub async fn open(path : String) -> Db raise DbError {
  let wal_bytes = read_all_bytes(wal_path(path))
  let replayed = replay_wal(wal_bytes)
  let bytes = read_all_bytes(path)
  let (meta, pages) = read_image(bytes, replayed)
  let tree = Tree::new()
  tree.root = meta.root
  tree.freelist = meta.freelist
  tree.next_page = meta.page_count
  for id, page in pages {
    tree.pages[id] = page
  }
  tree.validate()
  if !replayed.is_empty() {
    write_page_batch(path, replayed)
  }
  if !wal_bytes.is_empty() {
    write_synced_bytes(wal_path(path), b"")
  }
  {
    path,
    tree,
    txn_id: meta.txn_id,
    txn: None,
    closed: false,
    recovery_required: false,
  }
}

///|
fn require_open(db : Db) -> Unit raise DbError {
  guard !db.closed else { raise DbError::Closed }
  guard !db.recovery_required else { raise DbError::RecoveryRequired }
}

///|
fn require_txn(txn : Txn) -> Unit raise DbError {
  require_open(txn.db)
  match txn.state {
    Active => ()
    Committing => raise DbError::TxnBusy
    Ended => raise DbError::TxnClosed
    Failed => raise DbError::RecoveryRequired
  }
}

///|
#warnings("-unused_async")
/// 开始事务。已有未结束事务时抛 `DbError::TxnOpen`，库已关闭时抛 `DbError::Closed`。
pub async fn Db::begin(self : Db) -> Txn raise DbError {
  require_open(self)
  guard self.txn is None else { raise DbError::TxnOpen }
  self.tree.reset_changes()
  let txn = Txn::{
    db: self,
    base_root: self.tree.root,
    base_freelist: self.tree.freelist,
    base_next: self.tree.next_page,
    state: Active,
  }
  self.txn = Some(txn)
  txn
}

///|
#warnings("-unused_async")
/// 按版本 1 的 shortlex 顺序查找 `key`；只复制命中的 value。缺失返回 `None`。
pub async fn Txn::get(self : Txn, key : Bytes) -> Bytes? raise DbError {
  require_txn(self)
  self.db.tree.get(key)
}

///|
#warnings("-unused_async")
/// 写入或覆盖。容量超限抛 `ValueTooLarge`；失败保留事务中此前的全部修改。
pub async fn Txn::put(
  self : Txn,
  key : Bytes,
  value : Bytes,
) -> Unit raise DbError {
  require_txn(self)
  self.db.tree.put(key, value)
}

///|
#warnings("-unused_async")
/// 删除 `key`。键存在并已删除返回 `true`，否则返回 `false`。
pub async fn Txn::delete(self : Txn, key : Bytes) -> Bool raise DbError {
  require_txn(self)
  self.db.tree.delete(key)
}

///|
/// 同步 WAL 后定点写脏页并同步，再清空并同步 WAL。无修改时不做磁盘 I/O。
/// I/O 失败后抛 `Io`，句柄要求关闭并重新打开，不能再撤销或提交。
pub async fn Txn::commit(self : Txn) -> Unit raise DbError {
  self.commit_until(pause_after_wal=false)
}

///|
/// pause_after_wal 只给崩溃测试用：WAL 已落盘，页文件还是旧的
async fn Txn::commit_until(
  self : Txn,
  pause_after_wal~ : Bool,
) -> Unit raise DbError {
  require_txn(self)
  let tree = self.db.tree
  let dirty = tree.changed_pages()
  if dirty.is_empty() &&
    tree.root == self.base_root &&
    tree.freelist == self.base_freelist &&
    tree.next_page == self.base_next {
    tree.reset_changes()
    self.db.txn = None
    self.state = Ended
    return
  }
  guard self.db.txn_id < 0x7FFFFFFF else { raise DbError::Corrupt }
  let next_txn = self.db.txn_id + 1
  let header = page_bytes(
    encode_header({
      root: tree.root,
      freelist: tree.freelist,
      txn_id: next_txn,
      page_count: tree.next_page,
    }),
  )
  let pages : Map[Int, Bytes] = Map([])
  pages[0] = header
  let frames : Array[Frame] = [Data(txn_id=next_txn, page_id=0, page=header)]
  for id in dirty {
    if id != 0 {
      let page = match tree.pages.get(id) {
        Some(page) => page
        None => raise DbError::Corrupt
      }
      pages[id] = page
      frames.push(Data(txn_id=next_txn, page_id=id, page~))
    }
  }
  frames.push(Commit(txn_id=next_txn))
  let wal_bytes = encode_wal(frames)
  self.state = Committing
  errdefer {
    self.state = Failed
    self.db.recovery_required = true
  }
  write_synced_bytes(wal_path(self.db.path), wal_bytes)
  if pause_after_wal {
    return
  }
  write_page_batch(self.db.path, pages)
  write_synced_bytes(wal_path(self.db.path), b"")
  tree.pages[0] = header
  self.db.txn_id = next_txn
  tree.reset_changes()
  self.db.txn = None
  self.state = Ended
}

///|
#warnings("-unused_async")
/// 丢掉这次还没提交的写入，库回到上次 `commit` 的状态。
pub async fn Txn::abort(self : Txn) -> Unit raise DbError {
  require_txn(self)
  self.db.tree.rollback_changes(
    self.base_root,
    self.base_freelist,
    self.base_next,
  )
  self.db.txn = None
  self.state = Ended
}

///|
/// 关闭。事务还开着就丢掉它。之后再调用抛 `DbError::Closed`。
pub async fn Db::close(self : Db) -> Unit raise DbError {
  if self.txn is Some(txn) && txn.state is Committing {
    raise DbError::TxnBusy
  }
  if self.txn is Some(txn) {
    if self.recovery_required {
      txn.state = Ended
      self.txn = None
    } else {
      txn.abort()
    }
  }
  self.closed = true
}
