///|
/// 帧：kind(1=Data, 2=Commit)、txn_id(Int, LE u64)、page_id(LE u32)、payload、crc32(LE u32)。
///
/// 线格式固定 16 字节头 + 负载 + 4 字节 CRC：Data 负载 4096 字节页，Commit 负载 0 字节。
/// CRC 覆盖头部和负载，不含 CRC 自身。
/// `encode_wal` 精确预分配整段日志，保持版本 1 的线格式。
priv enum Frame {
  Data(txn_id~ : Int, page_id~ : Int, page~ : Bytes)
  Commit(txn_id~ : Int)
}

///|
fn frame_kind(frame : Frame) -> UInt {
  match frame {
    Data(_) => 1U
    Commit(_) => 2U
  }
}

///|
fn frame_txn_id(frame : Frame) -> Int {
  match frame {
    Data(txn_id~, ..) | Commit(txn_id~) => txn_id
  }
}

///|
fn frame_page_id(frame : Frame) -> Int {
  match frame {
    Data(page_id~, ..) => page_id
    Commit(_) => 0
  }
}

///|
fn frame_payload(frame : Frame) -> Bytes {
  match frame {
    Data(page~, ..) => page
    Commit(_) => b""
  }
}

///|
/// 单帧字节数：16 字节头 + 负载 + 4 字节 CRC。
fn frame_len(frame : Frame) -> Int {
  16 + frame_payload(frame).length() + 4
}

///|
/// 编码整段 WAL。精确预分配一次，逐帧写入，不做累加拼接。
fn encode_wal(frames : Array[Frame]) -> Bytes {
  let mut total = 0
  for frame in frames {
    total = total + frame_len(frame)
  }
  if total == 0 {
    return b""
  }
  let buf = FixedArray::make(total, b'\x00')
  let mut offset = 0
  for frame in frames {
    let payload = frame_payload(frame)
    write_u32(buf, offset, frame_kind(frame))
    write_u64_int(buf, offset + 4, frame_txn_id(frame))
    write_u32(buf, offset + 12, frame_page_id(frame).reinterpret_as_uint())
    buf.blit_from_bytes(offset + 16, payload, 0, payload.length())
    // This borrowed alias is read completely before the buffer is mutated again.
    let checksum = crc32(
      buf.unsafe_reinterpret_as_bytes()[offset:offset + 16 + payload.length()],
    )
    write_u32(buf, offset + 16 + payload.length(), checksum)
    offset = offset + 16 + payload.length() + 4
  }
  Bytes::from_array(buf[:])
}

///|
/// 重放 WAL，返回所有已提交事务写入的页：页 id 到 4096 字节页。
///
/// 契约（调用方按此分支处理）：
/// 不完整的已知帧尾部被忽略；完整帧的字段或 CRC 损坏抛 `Corrupt`。
/// 不重新同步。未提交帧不进入结果；同一页最后一次提交的值生效。
fn replay_wal(wal : Bytes) -> Map[Int, Bytes] raise DbError {
  // 挂起的事务：txn_id -> (页 id, 页视图)。视图在提交前不复制。
  let pending : Map[Int, Map[Int, BytesView]] = Map([])
  let committed : Map[Int, Bytes] = Map([])
  let mut offset = 0
  while offset + 20 <= wal.length() {
    let kind = read_u32(wal, offset)
    let payload_len = match kind {
      1U => page_size
      2U => 0
      _ => raise DbError::Corrupt
    }
    let frame_len = 16 + payload_len + 4
    if offset + frame_len > wal.length() {
      // 尾部半帧：崩溃只写了一半。等价的“忽略不完整尾部”。
      break
    }
    let stored = read_u32(wal, offset + 16 + payload_len)
    guard crc32(wal[offset:offset + 16 + payload_len]) == stored else {
      raise DbError::Corrupt
    }
    let txn_id = read_u64_as_int(wal, offset + 4)
    let page_id = read_u32(wal, offset + 12).reinterpret_as_int()
    if kind == 1U {
      guard page_id >= 0 else { raise DbError::Corrupt }
      let pages = match pending.get(txn_id) {
        Some(pages) => pages
        None => Map([])
      }
      pages[page_id] = wal[offset + 16:offset + 16 + page_size]
      pending[txn_id] = pages
    } else {
      guard page_id == 0 else { raise DbError::Corrupt }
      if pending.get(txn_id) is Some(pages) {
        for id, page in pages {
          committed[id] = page.to_owned()
        }
        pending.remove(txn_id)
      }
    }
    offset = offset + frame_len
  }
  committed
}
