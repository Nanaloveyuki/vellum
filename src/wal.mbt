///|
priv enum Frame {
  Data(txn_id~ : Int, page_id~ : Int, page~ : Bytes)
  Commit(txn_id~ : Int)
}

///|
/// 帧：kind、txn_id、page_id、payload_len、payload、crc32
fn encode_frame(frame : Frame) -> Bytes {
  let kind = match frame {
    Data(_) => 1U
    Commit(_) => 2U
  }
  let txn_id = match frame {
    Data(txn_id~, ..) | Commit(txn_id~) => txn_id
  }
  let page_id = match frame {
    Data(page_id~, ..) => page_id
    Commit(_) => 0
  }
  let payload = match frame {
    Data(page~, ..) => page
    Commit(_) => b""
  }
  let buf = FixedArray::make(16 + payload.length() + 4, b'\x00')
  write_u32(buf, 0, kind)
  write_u64_int(buf, 4, txn_id)
  write_u32(buf, 12, page_id.reinterpret_as_uint())
  buf.blit_from_bytes(16, payload, 0, payload.length())
  let covered = fixed_to_bytes(buf)[0:16 + payload.length()]
  write_u32(buf, 16 + payload.length(), crc32(owned_bytes(covered)))
  fixed_to_bytes(buf)
}

///|
priv struct Wal {
  mut bytes : Bytes
}

///|
fn Wal::new() -> Wal {
  { bytes: b"", }
}

///|
fn Wal::append(self : Wal, frame : Frame) -> Unit {
  self.bytes = self.bytes + encode_frame(frame)
}

///|
fn Wal::truncate(self : Wal) -> Unit {
  self.bytes = b""
}

///|
/// 只保留校验通过、且属于已提交事务的数据帧。尾部半帧丢掉
fn Wal::replay(self : Wal) -> Map[Int, Bytes] raise DbError {
  let mut offset = 0
  let pending : Map[Int, Array[(Int, Bytes)]] = Map([])
  let committed : Map[Int, Bytes] = Map([])
  while offset + 20 <= self.bytes.length() {
    let kind = read_u32(self.bytes, offset)
    let txn_id = read_u64_as_int(self.bytes, offset + 4)
    let page_id = read_u32(self.bytes, offset + 12).reinterpret_as_int()
    let payload_len = match kind {
      1U => page_size
      2U => 0
      _ => raise DbError::Corrupt
    }
    let frame_len = 16 + payload_len + 4
    if offset + frame_len > self.bytes.length() {
      break
    }
    let body = owned_bytes(self.bytes[offset:offset + 16 + payload_len])
    let stored = read_u32(self.bytes, offset + 16 + payload_len)
    if crc32(body) != stored {
      break
    }
    if kind == 1U {
      guard page_id >= 0 else { raise DbError::Corrupt }
      let page = owned_bytes(self.bytes[offset + 16:offset + 16 + page_size])
      let pages = match pending.get(txn_id) {
        Some(pages) => pages
        None => []
      }
      pages.push((page_id, page))
      pending[txn_id] = pages
    } else if pending.get(txn_id) is Some(pages) {
      for i in 0..<pages.length() {
        let (id, page) = pages[i]
        committed[id] = page
      }
      pending.remove(txn_id)
    }
    offset = offset + frame_len
  }
  committed
}
