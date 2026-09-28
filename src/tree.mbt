///|
priv struct Tree {
  pages : Map[Int, Bytes]
  mut root : Int
  mut freelist : Int
  mut next_page : Int
}

///|
fn Tree::new() -> Tree {
  { pages: Map([]), root: 0, freelist: 0, next_page: 1, }
}

///|
fn Tree::allocate(self : Tree) -> Int raise DbError {
  if self.freelist == 0 {
    let id = self.next_page
    self.next_page = id + 1
    id
  } else {
    let id = self.freelist
    let page = match self.pages.get(id) {
      Some(page) => page
      None => raise DbError::Corrupt
    }
    self.freelist = decode_free(page)
    id
  }
}

///|
fn Tree::release(self : Tree, id : Int) -> Unit {
  self.pages[id] = page_bytes(encode_free(self.freelist))
  self.freelist = id
}

///|
fn Tree::load(self : Tree, id : Int) -> Node raise DbError {
  match self.pages.get(id) {
    Some(page) => decode_node(page)
    None => raise DbError::Corrupt
  }
}

///|
fn Tree::store_leaf(self : Tree, id : Int, leaf : Leaf) -> Unit raise DbError {
  self.pages[id] = page_bytes(encode_leaf(leaf))
}

///|
fn Tree::store_branch(
  self : Tree,
  id : Int,
  branch : Branch,
) -> Unit raise DbError {
  self.pages[id] = page_bytes(encode_branch(branch))
}

///|
fn find_entry(entries : Array[Entry], key : Bytes) -> Int {
  let mut index = 0
  while index < entries.length() && compare_bytes(entries[index].key, key) < 0 {
    index = index + 1
  }
  index
}

///|
fn leaf_byte_size(leaf : Leaf) -> Int {
  let mut size = 7
  for entry in leaf.entries {
    size = size + 4 + entry.key.length() + entry.value.length()
  }
  size
}

///|
fn branch_byte_size(branch : Branch) -> Int {
  let mut size = 3 + branch.children.length() * 4
  for key in branch.keys {
    size = size + 2 + key.length()
  }
  size
}

///|
fn split_leaf(leaf : Leaf) -> (Leaf, Bytes, Leaf) raise DbError {
  let mid = leaf.entries.length() / 2
  guard mid > 0 && mid < leaf.entries.length() else { raise DbError::Corrupt }
  let left = leaf.entries[:mid].to_owned()
  let right = leaf.entries[mid:].to_owned()
  let separator = right[0].key
  (
    { entries: left, right: 0, },
    separator,
    { entries: right, right: leaf.right, },
  )
}

///|
fn split_branch(branch : Branch) -> (Branch, Bytes, Branch) raise DbError {
  let mid = branch.keys.length() / 2
  guard mid > 0 && mid < branch.keys.length() else { raise DbError::Corrupt }
  let separator = branch.keys[mid]
  let left = {
    keys: branch.keys[:mid].to_owned(),
    children: branch.children[:mid + 1].to_owned(),
  }
  let right = {
    keys: branch.keys[mid + 1:].to_owned(),
    children: branch.children[mid + 1:].to_owned(),
  }
  (left, separator, right)
}

///|
priv struct Split {
  separator : Bytes
  right : Int
}

///|
fn Tree::put(self : Tree, key : Bytes, value : Bytes) -> Unit raise DbError {
  guard value.length() <= max_value_len else { raise DbError::ValueTooLarge }
  if self.root == 0 {
    let id = self.allocate()
    self.store_leaf(id, { entries: [{ key, value, }], right: 0, })
    self.root = id
  } else {
    match self.insert(self.root, key, value) {
      None => ()
      Some(split) => {
        let id = self.allocate()
        self.store_branch(id, {
          keys: [split.separator],
          children: [self.root, split.right],
        })
        self.root = id
      }
    }
  }
}

///|
fn Tree::insert(
  self : Tree,
  id : Int,
  key : Bytes,
  value : Bytes,
) -> Split? raise DbError {
  match self.load(id) {
    Leaf(leaf) => self.insert_leaf(id, leaf, key, value)
    Branch(branch) => self.insert_branch(id, branch, key, value)
    Free => raise DbError::Corrupt
  }
}

///|
fn Tree::insert_leaf(
  self : Tree,
  id : Int,
  leaf : Leaf,
  key : Bytes,
  value : Bytes,
) -> Split? raise DbError {
  let index = find_entry(leaf.entries, key)
  if index < leaf.entries.length() &&
    compare_bytes(leaf.entries[index].key, key) == 0 {
    leaf.entries[index] = { key, value, }
  } else {
    leaf.entries.insert(index, { key, value, })
  }
  if leaf_byte_size(leaf) <= page_size {
    self.store_leaf(id, leaf)
    None
  } else {
    let (left, separator, right_leaf) = split_leaf(leaf)
    let right_id = self.allocate()
    self.store_leaf(id, { entries: left.entries, right: right_id, })
    self.store_leaf(right_id, {
      entries: right_leaf.entries,
      right: leaf.right,
    })
    Some({ separator, right: right_id, })
  }
}

///|
fn Tree::insert_branch(
  self : Tree,
  id : Int,
  branch : Branch,
  key : Bytes,
  value : Bytes,
) -> Split? raise DbError {
  let child_index = find_child_index(branch, key)
  match self.insert(branch.children[child_index], key, value) {
    None => None
    Some(split) => {
      branch.keys.insert(child_index, split.separator)
      branch.children.insert(child_index + 1, split.right)
      if branch_byte_size(branch) <= page_size {
        self.store_branch(id, branch)
        None
      } else {
        let (left, separator, right) = split_branch(branch)
        let right_id = self.allocate()
        self.store_branch(id, left)
        self.store_branch(right_id, right)
        Some({ separator, right: right_id, })
      }
    }
  }
}

///|
fn find_child_index(branch : Branch, key : Bytes) -> Int {
  let mut index = 0
  while index < branch.keys.length() &&
        compare_bytes(key, branch.keys[index]) >= 0 {
    index = index + 1
  }
  index
}

///|
fn Tree::get(self : Tree, key : Bytes) -> Bytes? raise DbError {
  if self.root == 0 {
    None
  } else {
    self.get_at(self.root, key)
  }
}

///|
fn Tree::get_at(self : Tree, id : Int, key : Bytes) -> Bytes? raise DbError {
  match self.load(id) {
    Leaf(leaf) => {
      let index = find_entry(leaf.entries, key)
      if index < leaf.entries.length() &&
        compare_bytes(leaf.entries[index].key, key) == 0 {
        Some(leaf.entries[index].value)
      } else {
        None
      }
    }
    Branch(branch) =>
      self.get_at(branch.children[find_child_index(branch, key)], key)
    Free => raise DbError::Corrupt
  }
}

///|
fn Tree::delete(self : Tree, key : Bytes) -> Bool raise DbError {
  if self.root == 0 {
    false
  } else {
    let removed = self.delete_at(self.root, key)
    if self.load(self.root) is Branch(branch) && branch.keys.length() == 0 {
      let only = branch.children[0]
      self.release(self.root)
      self.root = only
    }
    removed
  }
}

///|
fn Tree::delete_at(self : Tree, id : Int, key : Bytes) -> Bool raise DbError {
  match self.load(id) {
    Leaf(leaf) => {
      let index = find_entry(leaf.entries, key)
      if index < leaf.entries.length() &&
        compare_bytes(leaf.entries[index].key, key) == 0 {
        ignore(leaf.entries.remove(index))
        self.store_leaf(id, leaf)
        true
      } else {
        false
      }
    }
    Branch(branch) => {
      let index = find_child_index(branch, key)
      let removed = self.delete_at(branch.children[index], key)
      if removed {
        self.rebalance(id, branch, index)
      }
      removed
    }
    Free => raise DbError::Corrupt
  }
}

///|
fn Tree::rebalance(
  self : Tree,
  id : Int,
  branch : Branch,
  index : Int,
) -> Unit raise DbError {
  let child = branch.children[index]
  let undersized = match self.load(child) {
    Leaf(leaf) => leaf.entries.length() == 0
    Branch(inner) => inner.keys.length() == 0
    Free => raise DbError::Corrupt
  }
  if undersized {
    self.merge_child(branch, index)
    self.store_branch(id, branch)
  }
}

///|
fn Tree::merge_child(
  self : Tree,
  branch : Branch,
  index : Int,
) -> Unit raise DbError {
  let left_index = if index == 0 { 0 } else { index - 1 }
  let right_index = left_index + 1
  let left_id = branch.children[left_index]
  let right_id = branch.children[right_index]
  match (self.load(left_id), self.load(right_id)) {
    (Leaf(left), Leaf(right)) => {
      let merged = {
        entries: left.entries + right.entries,
        right: right.right,
      }
      guard leaf_byte_size(merged) <= page_size else {
        raise DbError::ValueTooLarge
      }
      self.store_leaf(left_id, merged)
    }
    (Branch(left), Branch(right)) => {
      left.keys.push(branch.keys[left_index])
      left.keys.append(right.keys)
      left.children.append(right.children)
      guard branch_byte_size(left) <= page_size else {
        raise DbError::ValueTooLarge
      }
      self.store_branch(left_id, left)
    }
    _ => raise DbError::Corrupt
  }
  self.release(right_id)
  ignore(branch.keys.remove(left_index))
  ignore(branch.children.remove(right_index))
}

///|
#warnings("-unused_value")
fn Tree::keys(self : Tree) -> Array[Bytes] raise DbError {
  if self.root == 0 {
    []
  } else {
    let mut id = self.leftmost(self.root)
    let keys = []
    while id != 0 {
      match self.load(id) {
        Leaf(leaf) => {
          for entry in leaf.entries {
            keys.push(entry.key)
          }
          id = leaf.right
        }
        _ => raise DbError::Corrupt
      }
    }
    keys
  }
}

///|
fn Tree::leftmost(self : Tree, id : Int) -> Int raise DbError {
  match self.load(id) {
    Leaf(_) => id
    Branch(branch) => self.leftmost(branch.children[0])
    Free => raise DbError::Corrupt
  }
}
