import Lean
open Lean

def main : IO Unit := do
  let s := "{\"username\":\"foo\",\"password\":\"bar\"}"
  match Json.parse s with
  | .ok j =>
    match j with
    | .obj m =>
      let u? := m.find? "username"
      let p? := m.find? "password"
      IO.println s!"u?={u?.isSome} p?={p?.isSome}"
    | _ => IO.println "not obj"
  | .error e => IO.println e
