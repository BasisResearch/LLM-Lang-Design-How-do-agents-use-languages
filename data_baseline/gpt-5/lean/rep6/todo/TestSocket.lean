import Socket

def main : IO Unit := do
  let s ← Socket.mk .inet
  s.close
  IO.println "ok"
