///|
// Called once on open; mutation and lookup do not rescan the whole database.
fn Tree::validate(self : Tree) -> Unit raise DbError {
  guard self.next_page >= 1 &&
    self.root >= 0 &&
    self.root < self.next_page &&
    self.freelist >= 0 &&
    self.freelist < self.next_page else {
    raise DbError::Corrupt
  }
  let visited : Map[Int, Bool] = Map([])
  let leaves : Array[(Int, Int)] = []
  let stack : Array[(Int, Bytes?, Bytes?)] = []
  if self.root != 0 {
    stack.push((self.root, None, None))
  }
  while stack.pop() is Some((id, lower, upper)) {
    guard id > 0 && id < self.next_page && !visited.contains(id) else {
      raise DbError::Corrupt
    }
    visited[id] = true
    let page = match self.pages.get(id) {
      Some(page) => page
      None => raise DbError::Corrupt
    }
    match decode_node(page) {
      Leaf(leaf) => {
        for entry in leaf.entries {
          if lower is Some(key) && compare_bytes(entry.key, key) < 0 {
            raise DbError::Corrupt
          }
          if upper is Some(key) && compare_bytes(entry.key, key) >= 0 {
            raise DbError::Corrupt
          }
        }
        guard leaf.right >= 0 && leaf.right < self.next_page else {
          raise DbError::Corrupt
        }
        leaves.push((id, leaf.right))
      }
      Branch(branch) => {
        for key in branch.keys {
          if lower is Some(bound) && compare_bytes(key, bound) < 0 {
            raise DbError::Corrupt
          }
          if upper is Some(bound) && compare_bytes(key, bound) >= 0 {
            raise DbError::Corrupt
          }
        }
        for i = branch.children.length() - 1; i >= 0; i = i - 1 {
          let child_lower = if i == 0 {
            lower
          } else {
            Some(branch.keys[i - 1])
          }
          let child_upper = if i == branch.keys.length() {
            upper
          } else {
            Some(branch.keys[i])
          }
          stack.push((branch.children[i], child_lower, child_upper))
        }
      }
      Free => raise DbError::Corrupt
    }
  }
  for i in 0..<leaves.length() {
    let (_, right) = leaves[i]
    let expected = if i + 1 < leaves.length() { leaves[i + 1].0 } else { 0 }
    guard right == expected else { raise DbError::Corrupt }
  }
  let mut id = self.freelist
  while id != 0 {
    guard id > 0 && id < self.next_page && !visited.contains(id) else {
      raise DbError::Corrupt
    }
    visited[id] = true
    let page = match self.pages.get(id) {
      Some(page) => page
      None => raise DbError::Corrupt
    }
    id = decode_free(page)
  }
}
