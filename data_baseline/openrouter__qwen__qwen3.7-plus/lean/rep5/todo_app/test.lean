import Std
def main : IO Unit := do
  let args ← IO.getArgs
  IO.println args.toList.length
