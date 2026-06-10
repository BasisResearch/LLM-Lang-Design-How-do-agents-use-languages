def main (args : List String) : IO UInt32 := do
  try
    let addr ← IO.Net.Addr.parse "0.0.0.0:1234"
    let _ ← IO.Net.Server.listen addr
    IO.println "ok"
  catch e =>
    IO.println s!"err: {e.toString}"
  pure 0
