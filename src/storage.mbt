///|
// Each worker owns at most one 64-page buffer and reuses it only after write_at joins.
async fn write_page_runs(
  file : @fs.File,
  pages : Map[Int, Bytes],
  ids : Array[Int],
  runs : Array[(Int, Int)],
  worker : Int,
  workers : Int,
) -> Unit {
  let mut buffer : FixedArray[Byte]? = None
  for index = worker; index < runs.length(); index = index + workers {
    let (start, count) = runs[index]
    let id = ids[start]
    let position = id.to_int64() * page_size.to_int64()
    if count == 1 {
      file.write_at(pages[id][:], position~)
    } else {
      let length = count * page_size
      let buf = match buffer {
        Some(buf) if buf.length() >= length => buf
        _ => {
          let buf = FixedArray::make(length, b'\x00')
          buffer = Some(buf)
          buf
        }
      }
      for i in 0..<count {
        buf.blit_from_bytes(i * page_size, pages[ids[start + i]], 0, page_size)
      }
      file.write_at(buf.unsafe_reinterpret_as_bytes()[:length], position~)
    }
  }
}

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
  let ids = []
  for id, page in pages {
    guard id >= 0 && page.length() == page_size else { raise DbError::Corrupt }
    if id != 0 {
      ids.push(id)
    }
  }
  ids.sort()
  let runs = []
  let mut start = 0
  while start < ids.length() {
    let mut count = 1
    while count < 64 &&
          start + count < ids.length() &&
          ids[start + count] == ids[start] + count {
      count += 1
    }
    runs.push((start, count))
    start += count
  }
  if ids.length() < 16 || runs.length() <= 1 {
    write_page_runs(file, pages, ids, runs, 0, 1) catch {
      err => raise io_error(err)
    }
  } else {
    let workers = runs.length().min(4)
    // Join every worker on success/error/cancellation before header, sync or close.
    @async.with_task_group(fn(group) {
      for worker in 0..<workers {
        group.spawn_bg(async fn() {
          write_page_runs(file, pages, ids, runs, worker, workers)
        })
      }
    }) catch {
      err => raise io_error(err)
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
