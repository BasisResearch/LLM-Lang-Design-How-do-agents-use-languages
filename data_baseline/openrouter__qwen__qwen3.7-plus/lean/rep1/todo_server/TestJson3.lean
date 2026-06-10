import Lean.Data.Json

open Lean.Json

def getStringField (j : Json) (key : String) : Option String :=
  match j with
  | Json.obj kv => 
    match kv.get? key with
    | some (Json.str s) => some s
    | _ => none
  | _ => none

def main : IO Unit := do
  let j := (parse "{\"a\": \"hello\"}").toOption
  IO.println (toString (getStringField j.getD Json.null "a"))
