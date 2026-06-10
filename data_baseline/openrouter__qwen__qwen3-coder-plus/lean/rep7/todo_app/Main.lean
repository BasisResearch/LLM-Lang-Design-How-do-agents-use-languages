import TodoApp.Logic

open TodoApp

-- Main function just prints the start of the server
def main : IO Unit := do
  println! s!"Starting Todo API server on 0.0.0.0:3000..."
  println!("TODO: Add HTTP server implementation with support for:")
  println!(" - --port PORT parsing")
  println!(" - Cookie-based authentication")
  println!(" - All required endpoints")
  println!(" - In-memory storage")