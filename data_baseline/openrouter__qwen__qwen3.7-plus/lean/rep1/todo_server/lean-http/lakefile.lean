import Lake
open Lake DSL

package «lean-http» where
  version := v!"0.1.0"

lean_lib «LeanHTTP» where
  srcDir := "."

lean_exe «example» where
  srcDir := "Examples"
  root := `Main

lean_exe «tests» where
  srcDir := "Tests"
  root := `Main
