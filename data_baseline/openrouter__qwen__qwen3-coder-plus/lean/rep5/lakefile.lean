import Lake
open Lake DSL

package "todo_app" {}

@[default_target]
lean_exe todo_app {
  root := `Main
}