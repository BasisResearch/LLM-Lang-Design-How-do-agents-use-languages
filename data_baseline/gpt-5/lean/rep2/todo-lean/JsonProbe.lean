import Lean
open Lean

def main : IO Unit := do
  let j := Json.mkObj [("a", .num 1), ("b", .bool true)]
  let s := j.compress
  IO.println s
