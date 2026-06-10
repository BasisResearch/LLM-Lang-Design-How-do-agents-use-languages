import Lake
open Lake DSL

package todo

lean_lib Server

lean_exe todo where
  root := `Main

require batteries from git
  "https://github.com/leanprover-community/batteries" @ "v4.8.0"