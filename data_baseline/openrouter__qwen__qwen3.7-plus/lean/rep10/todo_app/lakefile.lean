import Lake
open Lake DSL

package todo_app where
  version := v!"0.1.0"

@[default_target]
lean_exe todo_app where
  root := `Main
