import Lake
open Lake DSL

package «todo» where

@[default_target]
lean_exe «todo» where
  root := `Main
