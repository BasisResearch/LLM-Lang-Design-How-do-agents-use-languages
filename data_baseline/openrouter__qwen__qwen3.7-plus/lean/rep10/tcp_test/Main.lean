import Std.Internal.Async.TCP
import Std.Net.Addr

def main : IO Unit := do
  let listener ← Std.Internal.IO.Async.TCP.Socket.Server.mk
  let ipv4 : Option Std.Net.IPv4Addr := Std.Net.IPv4Addr.ofString "0.0.0.0"
  match ipv4 with
  | none => IO.println "Failed to parse"
  | some ip =>
    let sa : Std.Net.SocketAddressV4 := { addr := ip, port := 8080 }
    let addr : Std.Net.SocketAddress := sa
    listener.bind addr
    IO.println "Listening on 8080"
    listener.listen 128
    let conn ← listener.accept.wait
    IO.println "Connection accepted"
