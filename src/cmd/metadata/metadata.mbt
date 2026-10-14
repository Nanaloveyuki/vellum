///|
struct Record {
  path : String
  size : Int64
  mtime : Int64
} derive(Eq, Debug)

///|
suberror MetadataError {
  InvalidPath
  InvalidSize
  MissingRecord
  RenameConflict
  InvalidRecord
} derive(Eq, Debug)

///|
fn validate_path(
  path : String,
  root? : Bool = false,
) -> Unit raise MetadataError {
  if root && path.is_empty() {
    return
  }
  guard !path.is_empty() && !path.contains_any(chars="\u0000\\") else {
    raise InvalidPath
  }
  if path.length() >= 2 &&
    path[1] == ':' &&
    ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) {
    raise InvalidPath
  }
  for part in path.split("/") {
    guard part != "" && part != "." && part != ".." else { raise InvalidPath }
  }
}

///|
fn parent(path : String) -> String {
  match path.rev_split_once("/") {
    Some((directory, _)) => directory.to_owned()
    None => ""
  }
}

///|
fn primary_key(path : String) -> Bytes {
  let path = @utf8.encode(path)
  Bytes::makei(1 + path.length(), i => if i == 0 { b'm' } else { path[i - 1] })
}

///|
fn directory_prefix(directory : String) -> Bytes {
  let directory = @utf8.encode(directory)
  Bytes::makei(directory.length() + 2, i => {
    if i == 0 {
      b'd'
    } else if i == directory.length() + 1 {
      b'\x00'
    } else {
      directory[i - 1]
    }
  })
}

///|
fn directory_key(record : Record) -> Bytes {
  let directory = @utf8.encode(parent(record.path))
  let path = @utf8.encode(record.path)
  Bytes::makei(2 + directory.length() + path.length(), i => {
    if i == 0 {
      b'd'
    } else if i <= directory.length() {
      directory[i - 1]
    } else if i == directory.length() + 1 {
      b'\x00'
    } else {
      path[i - directory.length() - 2]
    }
  })
}

///|
fn time_key(record : Record) -> Bytes {
  let ordered = record.mtime.reinterpret_as_uint64() ^ 0x8000000000000000UL
  let path = @utf8.encode(record.path)
  Bytes::makei(9 + path.length(), i => {
    if i == 0 {
      b't'
    } else if i < 9 {
      (ordered >> ((8 - i) * 8)).to_byte()
    } else {
      path[i - 9]
    }
  })
}

///|
fn record_bytes(record : Record) -> Bytes {
  let bytes = FixedArray::make(16, b'\x00')
  bytes.unsafe_write_uint64_le(0, record.size.reinterpret_as_uint64())
  bytes.unsafe_write_uint64_le(8, record.mtime.reinterpret_as_uint64())
  Bytes::from_array(bytes)
}

///|
fn decode_record(path : String, bytes : Bytes) -> Record raise MetadataError {
  guard bytes.length() == 16 else { raise InvalidRecord }
  let size = bytes.unsafe_read_uint64_le(0).reinterpret_as_int64()
  guard size >= 0L else { raise InvalidRecord }
  { path, size, mtime: bytes.unsafe_read_uint64_le(8).reinterpret_as_int64(), }
}

///|
async fn get_record(txn : @vellum.Txn, path : String) -> Record? {
  match txn.get(primary_key(path)) {
    Some(bytes) => Some(decode_record(path, bytes))
    None => None
  }
}

///|
async fn delete_record(txn : @vellum.Txn, record : Record) -> Unit {
  ignore(txn.delete(directory_key(record)))
  ignore(txn.delete(time_key(record)))
  ignore(txn.delete(primary_key(record.path)))
}

///|
async fn put_record(txn : @vellum.Txn, record : Record) -> Unit {
  if get_record(txn, record.path) is Some(old) {
    delete_record(txn, old)
  }
  txn.put(primary_key(record.path), record_bytes(record))
  txn.put(time_key(record), b"")
  txn.put(directory_key(record), b"")
}

///|
async fn abort_update(txn : @vellum.Txn) -> Unit noraise {
  @async.protect_from_cancel(() => txn.abort()) catch {
    _ => ()
  }
}

///|
async fn upsert(db : @vellum.Db, record : Record) -> Unit {
  validate_path(record.path)
  guard record.size >= 0L else { raise InvalidSize }
  let txn = db.begin()
  {
    errdefer abort_update(txn)
    put_record(txn, record)
  }
  txn.commit()
}

///|
async fn remove(db : @vellum.Db, path : String) -> Bool {
  validate_path(path)
  let txn = db.begin()
  let removed = {
    errdefer abort_update(txn)
    match get_record(txn, path) {
      Some(record) => {
        delete_record(txn, record)
        true
      }
      None => false
    }
  }
  txn.commit()
  removed
}

///|
async fn rename_record(
  db : @vellum.Db,
  source : String,
  destination : String,
) -> Unit {
  validate_path(source)
  validate_path(destination)
  let txn = db.begin()
  {
    errdefer abort_update(txn)
    let record = match get_record(txn, source) {
      Some(record) => record
      None => raise MissingRecord
    }
    if source != destination {
      guard get_record(txn, destination) is None else { raise RenameConflict }
      delete_record(txn, record)
      put_record(txn, { ..record, path: destination, })
    }
  }
  txn.commit()
}

///|
async fn by_directory(db : @vellum.Db, directory : String) -> Array[Record] {
  validate_path(directory, root=true)
  let txn = db.begin()
  defer abort_update(txn)
  let prefix = directory_prefix(directory)
  let cursor = txn.scan_prefix(prefix)
  let records = []
  while cursor.next() is Some((key, _)) {
    let path = @utf8.decode(key[prefix.length():])
    match get_record(txn, path) {
      Some(record) => records.push(record)
      None => raise InvalidRecord
    }
  }
  records
}

///|
async fn by_time(db : @vellum.Db) -> Array[Record] {
  let txn = db.begin()
  defer abort_update(txn)
  let cursor = txn.scan_prefix(b"t")
  let records = []
  while cursor.next() is Some((key, _)) {
    guard key.length() >= 9 else { raise InvalidRecord }
    let path = @utf8.decode(key[9:])
    match get_record(txn, path) {
      Some(record) => records.push(record)
      None => raise InvalidRecord
    }
  }
  records
}

///|
async fn verify_all(db : @vellum.Db, records : Array[Record]) -> Unit {
  let expected : Map[String, Record] = Map([])
  let directories : Map[String, Bool] = Map([])
  for record in records {
    expected[record.path] = record
    directories[parent(record.path)] = true
  }
  {
    let txn = db.begin()
    defer abort_update(txn)
    let cursor = txn.scan(b"")
    let mut primary_count = 0
    let mut directory_count = 0
    let mut time_count = 0
    while cursor.next() is Some((key, value)) {
      guard key.length() > 0 else { raise InvalidRecord }
      match key[0] {
        b'm' => {
          let path = @utf8.decode(key[1:])
          assert_eq(Some(decode_record(path, value)), expected.get(path))
          primary_count += 1
        }
        b'd' => {
          assert_eq(value, b"")
          directory_count += 1
        }
        b't' => {
          assert_eq(value, b"")
          time_count += 1
        }
        _ => raise InvalidRecord
      }
    }
    assert_eq(primary_count, records.length())
    assert_eq(directory_count, records.length())
    assert_eq(time_count, records.length())
  }
  for directory, _ in directories {
    let direct = records.filter(record => parent(record.path) == directory)
    direct.sort_by((a, b) => {
      @utf8.encode(a.path).lexical_compare(@utf8.encode(b.path))
    })
    assert_eq(by_directory(db, directory), direct)
  }
  let chronological = records.copy()
  chronological.sort_by((a, b) => {
    let order = a.mtime.compare(b.mtime)
    if order != 0 {
      order
    } else {
      @utf8.encode(a.path).lexical_compare(@utf8.encode(b.path))
    }
  })
  assert_eq(by_time(db), chronological)
}
