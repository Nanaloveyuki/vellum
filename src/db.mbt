///|
/// 打开的页库。一个路径对应一个文件，同时只能有一个事务。
pub struct Db {
  priv path : String
  priv tree : Tree
  priv mut txn_id : Int
  priv mut txn : Txn?
  priv mut closed : Bool
}

///|
/// 当前这一次读写。`commit` 之后别的 `open` 才能看见；`abort` 则回到上次提交。
pub struct Txn {
  priv db : Db
  priv base_pages : Map[Int, Bytes]
  priv base_root : Int
  priv base_freelist : Int
  priv base_next : Int
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
async fn write_all_bytes(path : String, bytes : Bytes) -> Unit raise DbError {
  @fs.write_file(path, bytes, create_mode=@fs.CreateOrTruncate, sync=@fs.Full) catch {
    err => raise io_error(err)
  }
}

///|
fn wal_path(path : String) -> String {
  "\{path}.wal"
}

///|
async fn read_page_file(path : String) -> (Meta, Map[Int, Bytes]) raise DbError {
  let bytes = read_all_bytes(path)
  if bytes.length() == 0 {
    let meta = { root: 0, freelist: 0, txn_id: 0, page_count: 1, }
    (meta, Map([]))
  } else {
    guard bytes.length() % page_size == 0 else { raise DbError::Corrupt }
    let meta = decode_header(owned_bytes(bytes[0:page_size]))
    guard meta.page_count * page_size == bytes.length() else {
      raise DbError::Corrupt
    }
    let pages : Map[Int, Bytes] = Map([])
    for id in 1..<meta.page_count {
      pages[id] = owned_bytes(bytes[id * page_size:(id + 1) * page_size])
    }
    (meta, pages)
  }
}

///|
fn apply_pages(tree : Tree, pages : Map[Int, Bytes]) -> Unit {
  for id, page in pages {
    if id != 0 {
      tree.pages[id] = page
    }
  }
}

///|
fn file_image(tree : Tree, txn_id : Int) -> Bytes {
  let meta = {
    root: tree.root,
    freelist: tree.freelist,
    txn_id,
    page_count: tree.next_page,
  }
  let mut image = page_bytes(encode_header(meta))
  for id in 1..<tree.next_page {
    let page = match tree.pages.get(id) {
      Some(page) => page
      None => page_bytes(blank_page())
    }
    image = image + page
  }
  image
}

///|
/// 打开 `path`。文件不存在就创建。若有 `path.wal`，只重放校验通过且已提交的帧，然后把 WAL 清空。
pub async fn open(path : String) -> Db raise DbError {
  let (meta, pages) = read_page_file(path)
  let tree = Tree::new()
  tree.root = meta.root
  tree.freelist = meta.freelist
  tree.next_page = meta.page_count
  apply_pages(tree, pages)
  let wal_bytes = read_all_bytes(wal_path(path))
  if wal_bytes.length() > 0 {
    let wal = Wal::new()
    wal.bytes = wal_bytes
    let replayed = wal.replay()
    if replayed.length() > 0 {
      apply_pages(tree, replayed)
      if replayed.get(0) is Some(header) {
        let replay_meta = decode_header(header)
        tree.root = replay_meta.root
        tree.freelist = replay_meta.freelist
        tree.next_page = replay_meta.page_count
      }
      write_all_bytes(path, file_image(tree, tree_txn(tree, meta.txn_id)))
    }
    wal.truncate()
    write_all_bytes(wal_path(path), wal.bytes)
  }
  {
    path,
    tree,
    txn_id: meta_txn_after_replay(meta, tree),
    txn: None,
    closed: false,
  }
}

///|
fn tree_txn(tree : Tree, fallback : Int) -> Int {
  match tree.pages.get(0) {
    Some(header) =>
      try decode_header(header) catch {
        _ => fallback
      } noraise {
        meta => meta.txn_id
      }
    None => fallback
  }
}

///|
fn meta_txn_after_replay(meta : Meta, tree : Tree) -> Int {
  let from_header = tree_txn(tree, meta.txn_id)
  if from_header > meta.txn_id {
    from_header
  } else {
    meta.txn_id
  }
}

///|
fn require_open(db : Db) -> Unit raise DbError {
  guard !db.closed else { raise DbError::Closed }
}

///|
#warnings("-unused_async")
/// 开始事务。已有未结束事务时抛 `DbError::TxnOpen`，库已关闭时抛 `DbError::Closed`。
pub async fn Db::begin(self : Db) -> Txn raise DbError {
  require_open(self)
  guard self.txn is None else { raise DbError::TxnOpen }
  let base_pages : Map[Int, Bytes] = Map([])
  for id, page in self.tree.pages {
    base_pages[id] = page
  }
  let txn = Txn::{
    db: self,
    base_pages,
    base_root: self.tree.root,
    base_freelist: self.tree.freelist,
    base_next: self.tree.next_page,
  }
  self.txn = Some(txn)
  txn
}

///|
#warnings("-unused_async")
/// 按字节序查找 `key`。没有这个键时返回 `None`。
pub async fn Txn::get(self : Txn, key : Bytes) -> Bytes? raise DbError {
  require_open(self.db)
  self.db.tree.get(key)
}

///|
#warnings("-unused_async")
/// 写入或覆盖。`value` 长于 `max_value_len`，或这一页放不下时，抛 `DbError::ValueTooLarge`。
pub async fn Txn::put(
  self : Txn,
  key : Bytes,
  value : Bytes,
) -> Unit raise DbError {
  require_open(self.db)
  self.db.tree.put(key, value)
}

///|
#warnings("-unused_async")
/// 删除 `key`。键存在并已删除返回 `true`，否则返回 `false`。
pub async fn Txn::delete(self : Txn, key : Bytes) -> Bool raise DbError {
  require_open(self.db)
  self.db.tree.delete(key)
}

///|
fn dirty_pages(txn : Txn) -> Array[Int] {
  let ids = []
  let mut seen_max = txn.base_next
  if txn.db.tree.next_page > seen_max {
    seen_max = txn.db.tree.next_page
  }
  for id in 0..<seen_max {
    let before = txn.base_pages.get(id)
    let after = txn.db.tree.pages.get(id)
    if before != after {
      ids.push(id)
    }
  }
  if txn.base_root != txn.db.tree.root ||
    txn.base_freelist != txn.db.tree.freelist ||
    txn.base_next != txn.db.tree.next_page {
    if !ids.contains(0) {
      ids.push(0)
    }
  }
  ids
}

///|
/// 落盘。先把脏页和提交帧同步到 WAL，再写入页文件，最后清空 WAL。
pub async fn Txn::commit(self : Txn) -> Unit raise DbError {
  self.commit_until(pause_after_wal=false)
}

///|
/// pause_after_wal 只给崩溃测试用：WAL 已落盘，页文件还是旧的
async fn Txn::commit_until(
  self : Txn,
  pause_after_wal~ : Bool,
) -> Unit raise DbError {
  require_open(self.db)
  let next_txn = self.db.txn_id + 1
  self.db.tree.pages[0] = page_bytes(
    encode_header({
      root: self.db.tree.root,
      freelist: self.db.tree.freelist,
      txn_id: next_txn,
      page_count: self.db.tree.next_page,
    }),
  )
  let wal = Wal::new()
  for id in dirty_pages(self) {
    let page = match self.db.tree.pages.get(id) {
      Some(page) => page
      None => raise DbError::Corrupt
    }
    wal.append(Data(txn_id=next_txn, page_id=id, page~))
  }
  wal.append(Commit(txn_id=next_txn))
  write_all_bytes(wal_path(self.db.path), wal.bytes)
  if !pause_after_wal {
    write_all_bytes(self.db.path, file_image(self.db.tree, next_txn))
    wal.truncate()
    write_all_bytes(wal_path(self.db.path), wal.bytes)
    self.db.txn_id = next_txn
    self.db.txn = None
  }
}

///|
#warnings("-unused_async")
/// 丢掉这次还没提交的写入，库回到上次 `commit` 的状态。
pub async fn Txn::abort(self : Txn) -> Unit raise DbError {
  require_open(self.db)
  self.db.tree.pages.clear()
  for id, page in self.base_pages {
    self.db.tree.pages[id] = page
  }
  self.db.tree.root = self.base_root
  self.db.tree.freelist = self.base_freelist
  self.db.tree.next_page = self.base_next
  self.db.txn = None
}

///|
/// 关闭。事务还开着就丢掉它。之后再调用抛 `DbError::Closed`。
pub async fn Db::close(self : Db) -> Unit raise DbError {
  if self.txn is Some(txn) {
    txn.abort()
  }
  self.closed = true
}
