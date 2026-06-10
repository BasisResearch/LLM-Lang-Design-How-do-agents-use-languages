def main : IO Unit := do
  let args ← IO.getArgs
  IO.println s!"args: {args.toList}"
