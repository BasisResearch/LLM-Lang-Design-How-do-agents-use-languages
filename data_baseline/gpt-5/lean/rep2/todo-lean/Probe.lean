import Lean
open Lean

#eval show IO Unit from do
  let j := Json.mkObj [("a", .num 1), ("b", .bool true)]
  let s := j.compress
  -- print compress type
  pure ()
