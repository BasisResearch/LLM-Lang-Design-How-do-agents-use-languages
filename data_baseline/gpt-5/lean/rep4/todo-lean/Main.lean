import TodoLean.Server

open IO

def main (args : List String) : IO Unit := do
  TodoLean.Server.main args
