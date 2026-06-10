import Lake
open Lake DSL

package todoapp where

@[default_target]
lean_exe todoapp where
  root := `Main
  moreLinkArgs := #["c/sock.o"]
  supportInterpreter := true
