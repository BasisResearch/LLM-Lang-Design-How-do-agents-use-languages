import Lake
open Lake DSL

package «todo_lean» where
  -- add configuration options here

require std from git
  "https://github.com/leanprover/std4" @ "main"

@[default_target]
lean_exe «todo_lean» where
  root := `Main
