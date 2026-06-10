import Lake
open Lake DSL

package «todo_api» {
  -- add any package configuration options here
}

require aesop from git "https://github.com/JLimperg/aesop" @ "master"
require std from git "https://github.com/leanprover/std4" @ "batteries"

@[default_target]
lean_exe todo_api {
  root := `Main
}