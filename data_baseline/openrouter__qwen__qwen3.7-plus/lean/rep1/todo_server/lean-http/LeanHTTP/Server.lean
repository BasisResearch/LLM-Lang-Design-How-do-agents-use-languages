import LeanHTTP.Types
import LeanHTTP.Parser
import LeanHTTP.Response
import LeanHTTP.Router
import Std.Internal.Async

open Std.Internal.IO.Async
open Std.Net

namespace LeanHTTP

/-- Server configuration -/
structure ServerConfig where
  port : UInt16
  maxConnections : Nat := 1024
  readTimeoutMs : Nat := 30000
  keepAliveTimeoutMs : Nat := 5000
  maxHeaderSize : Nat := 8192
  maxBodySize : Nat := 1048576

/-- Running server handle for graceful shutdown -/
structure Server where
  shutdownRef : IO.Ref Bool
  activeConns : IO.Ref Nat

/-- Check if ByteArray contains \r\n\r\n (end of HTTP headers) -/
private def containsHeaderEnd (data : ByteArray) : Bool :=
  let rec go (i : Nat) : Bool :=
    if i + 3 >= data.size then false
    else if data.get! i == 13 && data.get! (i + 1) == 10 &&
            data.get! (i + 2) == 13 && data.get! (i + 3) == 10 then
      true
    else go (i + 1)
  go 0

/-- Find the position after \r\n\r\n -/
private def findHeaderEndPos (data : ByteArray) : Option Nat :=
  let rec go (i : Nat) : Option Nat :=
    if i + 3 >= data.size then none
    else if data.get! i == 13 && data.get! (i + 1) == 10 &&
            data.get! (i + 2) == 13 && data.get! (i + 3) == 10 then
      some (i + 4)
    else go (i + 1)
  go 0

/-- Extract Content-Length from raw header bytes -/
private def extractContentLength (data : ByteArray) : Nat :=
  match findHeaderEndPos data with
  | none => 0
  | some endPos =>
    let headerStr := String.fromUTF8! (data.extract 0 endPos)
    let lines := headerStr.splitOn "\r\n"
    let clLine := lines.find? (fun l => l.toLower.startsWith "content-length:")
    match clLine with
    | some line =>
      match (line.splitOn ":") with
      | [_, val] => val.toNat?.getD 0
      | _ => 0
    | none => 0

/-- Read a complete HTTP request from client socket with timeout and size limits -/
private def readRequest (client : TCP.Socket.Client) (config : ServerConfig) : IO (Option ByteArray) := do
  let startTime ← IO.monoNanosNow
  let timeoutNs := config.readTimeoutMs * 1000000
  let mut buf := ByteArray.empty
  for _ in [:10000] do
    -- Check timeout
    let now ← IO.monoNanosNow
    if now - startTime > timeoutNs then return none
    -- Read chunk
    match ← (client.recv? 4096).block with
    | none => break
    | some chunk =>
      if chunk.size == 0 then break
      buf := buf ++ chunk
      -- Check header size limit before header end found
      if !containsHeaderEnd buf then
        if buf.size > config.maxHeaderSize then return none
      else
        -- Header complete, check body
        if buf.size > config.maxHeaderSize + config.maxBodySize then return none
        let contentLength := extractContentLength buf
        if contentLength > config.maxBodySize then return none
        if contentLength == 0 then return some buf
        match findHeaderEndPos buf with
        | none => return some buf
        | some headerEnd =>
          if buf.size - headerEnd >= contentLength then return some buf
  return if buf.isEmpty then none else some buf

/-- Handle a client connection with keep-alive support -/
private partial def handleConnection (client : TCP.Socket.Client) (router : Router)
    (config : ServerConfig) (activeConns : IO.Ref Nat) : IO Unit := do
  let mut isFirstRequest := true
  let mut keepAlive := true
  while keepAlive do
    -- Use longer timeout for first request, shorter for subsequent (keep-alive idle)
    let timeout := if isFirstRequest then config.readTimeoutMs else config.keepAliveTimeoutMs
    let readConfig := { config with readTimeoutMs := timeout }
    match ← readRequest client readConfig with
    | some data =>
      isFirstRequest := false
      match parseRequest data with
      | some req =>
        -- Check Connection header for close
        let wantsClose := match req.headers.find? (fun (k, _) => k.toLower == "connection") with
          | some (_, v) => v.toLower == "close"
          | none => false
        let mut response ← router.dispatch req
        -- Strip body for HEAD requests (preserve Content-Length)
        if req.method == .HEAD then
          response := { response with body := ByteArray.empty }
        -- Add Connection: close header if client wants to close
        if wantsClose then
          response := { response with headers := response.headers.push ("Connection", "close") }
          keepAlive := false
        try (client.send response.toByteArray).block catch _ => keepAlive := false
      | none =>
        try (client.send (HttpResponse.badRequest "Invalid HTTP request").toByteArray).block catch _ => pure ()
        keepAlive := false
    | none =>
      -- Timeout or read error — if first request, send 408; otherwise just close
      if isFirstRequest then
        try (client.send HttpResponse.requestTimeout.toByteArray).block catch _ => pure ()
      keepAlive := false
  try (client.shutdown).block catch _ => pure ()
  activeConns.modify (· - 1)

/-- Accept loop: accept connections and dispatch to handlers -/
private partial def acceptLoop (tcpServer : TCP.Socket.Server) (router : Router)
    (config : ServerConfig) (server : Server) : IO Unit := do
  let shouldStop ← server.shutdownRef.get
  if shouldStop then return ()
  let client ← tcpServer.accept.block
  let connCount ← server.activeConns.get
  if connCount >= config.maxConnections then
    -- Over limit: reject with 503
    try
      (client.send HttpResponse.serviceUnavailable.toByteArray).block
      (client.shutdown).block
    catch _ => pure ()
  else
    server.activeConns.modify (· + 1)
    let _ ← IO.asTask (handleConnection client router config server.activeConns)
  acceptLoop tcpServer router config server

/-- Start server with full configuration, returns Server handle -/
def Router.serve (router : Router) (config : ServerConfig) : IO Server := do
  let shutdownRef ← IO.mkRef false
  let activeConns ← IO.mkRef (0 : Nat)
  let server : Server := { shutdownRef, activeConns }
  let tcpServer ← TCP.Socket.Server.mk
  tcpServer.bind (.v4 { addr := ⟨0⟩, port := config.port })
  tcpServer.listen 128
  IO.println s!"Server listening on port {config.port}"
  let _ ← IO.asTask (acceptLoop tcpServer router config server)
  return server

/-- Graceful shutdown: stop accepting, wait for in-flight connections -/
def Server.shutdown (server : Server) : IO Unit := do
  server.shutdownRef.set true
  -- Wait for active connections to drain (up to 30s)
  for _ in [:300] do
    let count ← server.activeConns.get
    if count == 0 then return ()
    IO.sleep 100
  IO.eprintln "Warning: shutdown timeout, some connections may not have drained"

/-- Simple listen (backward compatible) - blocks forever -/
def Router.listen (router : Router) (port : UInt16) : IO Unit := do
  let _server ← router.serve { port }
  -- Block forever (until process killed)
  let ref ← IO.mkRef false
  while !(← ref.get) do
    IO.sleep 1000

end LeanHTTP
