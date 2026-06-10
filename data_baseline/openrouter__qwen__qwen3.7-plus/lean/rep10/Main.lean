import Std.Net

def main : IO Unit := do
  let addr ← Std.Net.IPv4Addr.ofString "0.0.0.0"
  IO.println s!"Parsed: {addr}"
