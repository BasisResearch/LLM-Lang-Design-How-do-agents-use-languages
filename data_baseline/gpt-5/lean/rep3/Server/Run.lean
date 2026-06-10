import Server.Core
import Lean
import System

open Server
open System
open Lean

abbrev ServerState := Server.ServerState
abbrev Request := Server.Request
abbrev Response := Server.Response

open Server.Http

partial def handleConn (st : ServerState) (h : IO.FS.Handle) : IO Unit := do
  -- read all available until timeout or idle; for simplicity, read once
  let mut buf := ByteArray.empty
  let mut tmp : ByteArray := ByteArray.mkEmpty 4096
  let rec readLoop : IO Unit := do
    let chunk ← h.read 4096
    if chunk.isEmpty then
      pure ()
    else
      buf := buf ++ chunk
      if chunk.size < 4096 then pure () else readLoop
  readLoop
  let req := parseRawRequest buf
  let resp ← handleRequest st req
  let bytes := buildHttpBytes resp
  h.write bytes
  h.flush

-- Minimal TCP listener via stdio redirection using socat workaround not possible in Lean.
-- Here we fallback to using inetd-like mode: read one request from stdin and write response.
-- To integrate with run.sh, we will use a tiny bash wrapper that accepts TCP and invokes this binary per-connection.

def main (args : List String) : IO UInt32 := do
  -- When executed directly, behave as inetd filter: read stdin->stdout
  let st ← MVar.mk ({} : Server.State)
  let hIn ← IO.getStdin
  let hOut ← IO.getStdout
  -- Combine stdin to a single handle using a pipe: We use stdin as input and stdout as output already
  -- Read entire stdin
  let mut buf := ByteArray.empty
  let rec rl : IO Unit := do
    let chunk ← hIn.read 4096
    if chunk.isEmpty then pure () else buf := buf ++ chunk; rl
  rl
  let req := parseRawRequest buf
  let resp ← handleRequest st req
  let bytes := buildHttpBytes resp
  hOut.write bytes
  hOut.flush
  pure 0
