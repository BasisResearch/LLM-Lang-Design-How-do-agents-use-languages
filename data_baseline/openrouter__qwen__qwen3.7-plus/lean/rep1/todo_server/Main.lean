import TodoServer.Basic

def main : IO Unit := do
  let ref ← IO.mkRef TodoServer.initialState
  let app ← TodoServer.makeApp ref
  IO.println "Starting Todo Server on port 8080"
  app.listen 8080
