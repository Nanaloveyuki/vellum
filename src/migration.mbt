///|
async fn migration_kind(path : String) -> @fs.FileKind? raise DbError {
  try @fs.kind(path, follow_symlink=false) catch {
    @os_error.OSError(_, ..) as err if err.is_ENOENT() => None
    err => raise io_error(err)
  } noraise {
    kind => Some(kind)
  }
}

///|
async fn migration_path(path : String) -> String raise DbError {
  let path = if @async.platform is Windows {
    path.replace(old="\\", new="/")
  } else {
    path
  }
  let (parent, name) = match path.rev_find("/") {
    Some(index) =>
      (
        if index == 0 {
          "/"
        } else {
          path[:index].to_owned()
        },
        path[index + 1:].to_owned(),
      )
    None => (".", path)
  }
  guard !name.is_empty() && name != "." && name != ".." else {
    raise DbError::Io("migration requires a file basename")
  }
  let parent = @fs.realpath(parent) catch { err => raise io_error(err) }
  guard migration_kind(parent) == Some(@fs.Directory) else {
    raise DbError::Io("migration parent must be an existing directory")
  }
  if parent.has_suffix("/") {
    "\{parent}\{name}"
  } else {
    "\{parent}/\{name}"
  }
}

///|
fn migration_same_path(left : String, right : String) -> Bool {
  if @async.platform is Windows {
    left.to_lower() == right.to_lower()
  } else {
    left == right
  }
}

///|
async fn migration_require_absent(path : String) -> Unit raise DbError {
  guard migration_kind(path) == None else {
    raise DbError::Io("migration destination directory entry exists: \{path}")
  }
}

///|
async fn migration_read_source(path : String) -> Bytes raise DbError {
  match migration_kind(path) {
    None => b""
    Some(@fs.Regular) => {
      let data = @fs.read_file(path) catch { err => raise io_error(err) }
      data.binary()
    }
    Some(@fs.SymLink) =>
      raise DbError::Io("migration source symlink rejected: \{path}")
    Some(_) =>
      raise DbError::Io("migration source must be a regular file: \{path}")
  }
}

///|
fn migration_each_entry(
  pages : Map[Int, Bytes],
  visit : (BytesView, BytesView) -> Unit raise DbError,
) -> Int raise DbError {
  let mut count = 0
  for _, page in pages {
    if page[0] == kind_leaf {
      let mut offset = 7
      for _ in 0..<read_u16(page, 1) {
        let key_len = read_u16(page, offset)
        let value_len = read_u16(page, offset + 2)
        let key_start = offset + 4
        let value_start = key_start + key_len
        visit(
          page[key_start:value_start],
          page[value_start:value_start + value_len],
        )
        count += 1
        offset = value_start + value_len
      }
    }
  }
  count
}

///|
fn migration_value(tree : Tree, key : BytesView) -> BytesView? raise DbError {
  let mut id = tree.root
  let mut remaining = tree.next_page
  while id != 0 {
    guard id > 0 && id < tree.next_page && remaining > 0 else {
      raise DbError::Corrupt
    }
    remaining -= 1
    let page = tree.pages[id]
    let index = tree.page_index(id, page)
    let branch = page[0] == kind_branch
    let low = index_position(index, key, branch~)
    if branch {
      id = read_u32(page, 3 + low * 4).reinterpret_as_int()
    } else {
      guard low < index.offsets.length() else { return None }
      let offset = index.offsets[low]
      let start = offset + 4
      let key_len = read_u16(page, offset)
      guard page[start:start + key_len] == key else { return None }
      let value_len = read_u16(page, offset + 2)
      return Some(page[start + key_len:start + key_len + value_len])
    }
  }
  None
}

///|
fn migration_verify(
  tree : Tree,
  source : Map[Int, Bytes],
  expected : Int,
) -> Unit raise DbError {
  tree.validate()
  let mut actual = 0
  for id, page in tree.pages {
    if id != 0 && page[0] == kind_leaf {
      actual += read_u16(page, 1)
    }
  }
  guard actual == expected else { raise DbError::Corrupt }
  let verified = migration_each_entry(source, (key, value) => {
    guard migration_value(tree, key) == Some(value) else {
      raise DbError::Corrupt
    }
  })
  guard verified == expected else { raise DbError::Corrupt }
}

///|
/// 只读旧库及 WAL，在不同路径重建并核对 v2；目标主文件/WAL 目录项必须不存在。
/// 正常返回才算完成；错误或取消后检查 staging/目标，再由调用者显式切换路径。
pub async fn migrate_v1(
  source : String,
  destination : String,
) -> Unit raise DbError {
  let source = migration_path(source)
  let destination = migration_path(destination)
  let source_wal = wal_path(source)
  let destination_wal = wal_path(destination)
  guard !migration_same_path(source, destination) &&
    !migration_same_path(source, destination_wal) &&
    !migration_same_path(source_wal, destination) &&
    !migration_same_path(source_wal, destination_wal) else {
    raise DbError::Io("migration source and destination paths overlap")
  }
  migration_require_absent(destination)
  migration_require_absent(destination_wal)
  let wal_bytes = migration_read_source(source_wal)
  let replayed = replay_wal(wal_bytes)
  let bytes = migration_read_source(source)
  let (_, source_pages) = legacy_read_image(bytes, replayed)
  let tree = Tree::new()
  let count = migration_each_entry(source_pages, (key, value) => {
    tree.put(key.to_owned(), value.to_owned())
  })
  migration_verify(tree, source_pages, count)
  tree.pages[0] = page_bytes(
    encode_header({
      root: tree.root,
      freelist: tree.freelist,
      txn_id: 1,
      page_count: tree.next_page,
    }),
  )
  let random = @random.Rand::chacha8()
  let staging = "\{destination}.vellum-migrate-\{@async.now()}-\{random.uint64()}"
  let staging_wal = wal_path(staging)
  let file = @fs.create(staging, allow_existing=false, permission=0o600) catch {
    err => raise io_error(err)
  }
  file.close()
  // Cleanup only paths created exclusively by this call, never the final destination.
  defer migration_cleanup(staging)
  let wal_file = @fs.create(staging_wal, allow_existing=false, permission=0o600) catch {
    err => raise io_error(err)
  }
  wal_file.close()
  defer migration_cleanup(staging_wal)
  write_page_batch(staging, tree.pages)
  write_synced_bytes(staging_wal, b"")
  let persisted_bytes = migration_read_source(staging)
  let (meta, pages) = read_image(persisted_bytes, Map([]))
  let persisted = Tree::new()
  persisted.root = meta.root
  persisted.freelist = meta.freelist
  persisted.next_page = meta.page_count
  for id, page in pages {
    persisted.pages[id] = page
  }
  migration_verify(persisted, source_pages, count)
  migration_require_absent(destination_wal)
  @fs.rename(staging, destination, replace=false) catch {
    err => raise io_error(err)
  }
}

///|
async fn migration_cleanup(path : String) -> Unit noraise + nocancel {
  @fs.remove(path) catch {
    _ => ()
  }
}
