///|
async fn main {
  let path = "vellum-example.db"
  let db = @vellum.open(path)
  let txn = db.begin()
  txn.put(b"hello", b"vellum")
  txn.commit()
  db.close()
  let again = @vellum.open(path)
  let read = again.begin()
  match read.get(b"hello") {
    Some(value) => println(value.to_string())
    None => println("missing")
  }
  read.abort()
  again.close()
}
