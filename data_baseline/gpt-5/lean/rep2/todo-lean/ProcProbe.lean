import Lean
open IO

def main : IO Unit := do
  let child ← IO.Process.spawn { cmd := "bash", args := #["-lc", "echo hi"], stdin := .piped, stdout := .piped, stderr := .piped }
  -- Try to write to stdin, read from stdout
  (child.stdin).putStr ""
  (child.stdin).flush
  let out ← (child.stdout).readToEnd
  IO.println s!"OUT={out}"
  let code ← child.wait
  IO.println s!"CODE={code}"
