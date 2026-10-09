///|
priv struct CachedNode {
  page : Bytes
  node : Node
}

///|
fn copy_node(node : Node) -> Node {
  match node {
    Leaf(leaf) => Leaf({ entries: leaf.entries.copy(), right: leaf.right, })
    Branch(branch) =>
      Branch({ keys: branch.keys.copy(), children: branch.children.copy(), })
    Free => Free
  }
}

///|
fn Tree::cache_node(self : Tree, id : Int, page : Bytes, node : Node) -> Unit {
  if !self.node_cache.contains(id) {
    self.node_cache.remove(self.node_slots[self.node_next])
    self.node_slots[self.node_next] = id
    self.node_next = (self.node_next + 1) % self.node_slots.length()
  }
  // Store a container snapshot; callers continue mutating their own arrays.
  self.node_cache[id] = { page, node: copy_node(node), }
}
