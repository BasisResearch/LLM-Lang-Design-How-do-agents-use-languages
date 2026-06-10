import Lake
open Lake DSL

package todo_server {
  -- add any package configuration options here
}

@[default_target]
lean_lib TodoServerFixed {
  -- add any library configuration options here
}

lean_exe server {
  root := `Main
}