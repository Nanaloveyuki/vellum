///|
// Never truncate the page file: unchanged pages must survive interrupted commits.
async fn write_page_batch(
  path : String,
  pages : Map[Int, Bytes],
) -> Unit raise DbError {
  let file = @fs.open(
    path,
    mode=@fs.ReadWrite,
    create_mode=@fs.OpenOrCreate,
    sync=@fs.NoSync,
  ) catch {
    err => raise io_error(err)
  }
  defer file.close()
  for id, page in pages {
    if id != 0 {
      guard id > 0 && page.length() == page_size else { raise DbError::Corrupt }
      file.write_at(page[:], position=id.to_int64() * page_size.to_int64()) catch {
        err => raise io_error(err)
      }
    }
  }
  if pages.get(0) is Some(header) {
    file.write_at(header[:], position=0L) catch {
      err => raise io_error(err)
    }
  }
  file.sync(only_data=false) catch {
    err => raise io_error(err)
  }
}

///|
// An empty write still needs fsync: O_TRUNC alone is not a sync operation.
async fn write_synced_bytes(path : String, bytes : Bytes) -> Unit raise DbError {
  let file = @fs.open(
    path,
    mode=@fs.WriteOnly,
    create_mode=@fs.CreateOrTruncate,
    sync=@fs.NoSync,
  ) catch {
    err => raise io_error(err)
  }
  defer file.close()
  file.write(bytes) catch {
    err => raise io_error(err)
  }
  file.sync(only_data=false) catch {
    err => raise io_error(err)
  }
}

///|
fn read_image(
  bytes : Bytes,
  replayed : Map[Int, Bytes],
) -> (Meta, Map[Int, Bytes]) raise DbError {
  let header = match replayed.get(0) {
    Some(page) => page
    None if bytes.length() >= page_size => bytes[:page_size].to_owned()
    None if bytes.length() == 0 && replayed.is_empty() =>
      return ({ root: 0, freelist: 0, txn_id: 0, page_count: 1, }, Map([]))
    None => raise DbError::Corrupt
  }
  let meta = decode_header(header)
  guard meta.page_count >= 1 &&
    meta.page_count <= 0x7FFFFFFF / page_size &&
    meta.root >= 0 &&
    meta.root < meta.page_count &&
    meta.freelist >= 0 &&
    meta.freelist < meta.page_count else {
    raise DbError::Corrupt
  }
  let expected = meta.page_count * page_size
  guard bytes.length() <= expected else { raise DbError::Corrupt }
  if replayed.is_empty() {
    guard bytes.length() == expected else { raise DbError::Corrupt }
  } else {
    guard replayed.contains(0) else { raise DbError::Corrupt }
  }
  for id, page in replayed {
    guard id >= 0 && id < meta.page_count && page.length() == page_size else {
      raise DbError::Corrupt
    }
  }
  let pages : Map[Int, Bytes] = Map([])
  pages[0] = header
  for id in 1..<meta.page_count {
    let page = match replayed.get(id) {
      Some(page) => page
      None => {
        guard (id + 1) * page_size <= bytes.length() else {
          raise DbError::Corrupt
        }
        bytes[id * page_size:(id + 1) * page_size].to_owned()
      }
    }
    pages[id] = page
  }
  (meta, pages)
}
