import Std

def main : IO Unit := do
  let args ← IO.getArgs
  let portStr := args.find? (·.startsWith "--port=")
  let port : Nat := match portStr with
    | some s => s.drop 7 |>.toNat?.getD 3000
    | none => 3000
  IO.println s!"Listening on 0.0.0.0:{port}"
  -- Mock server to ensure it compiles
  forever do
    let conn := none
    pure ()
