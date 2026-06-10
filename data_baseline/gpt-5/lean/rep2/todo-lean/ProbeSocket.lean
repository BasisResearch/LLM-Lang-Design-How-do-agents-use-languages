import Lean
open IO

def main : IO Unit := do
  let addr := Socket.Address.v4 0 0 0 0 (port := 8081)
  let sock ← Socket.mk Socket.Family.inet Socket.Type.stream Socket.Protocol.tcp
  sock.setOption Socket.Option.reuseAddr true
  sock.bind addr
  sock.listen 10
  IO.println "ok"
  sock.close
