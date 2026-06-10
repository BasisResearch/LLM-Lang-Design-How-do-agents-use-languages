import Lake
open Lake DSL

package «todo-app» {
  -- add any package configuration options here
}

require std from git
  "https://github.com/leanprover/std4" @ "v4.30.0"

@[default_target]
lean_lib «TodoApp» {
  -- add library configuration options here
}

@[default_target]
lean_exe todo_app {
  root := `Main
}