import Lean
open Lean

#eval show IO Unit from do
  let s := "{\"a\": 1, \"b\": true}"
  match Json.parse s with
  | .ok j =>
    let some obj := j.getObj? | IO.println "no obj"
    pure ()
  | .error e => IO.println ("err" ++ e)
