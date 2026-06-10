import Lake
open Lake DSL

package todo_api where
  version := v!"0.1.0"

require "lean-http" from git "https://github.com/kaito2/lean-http" @ "main"

lean_lib «TodoApi» where

lean_exe «todo_api» where
  root := `Main
