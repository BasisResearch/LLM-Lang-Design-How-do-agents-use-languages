import Std
import Lean.Data.Json

open Std
open Lean

structure User where
  id : Nat
  username : String
  password : String
  deriving Repr

structure Todo where
  id : Nat
  userId : Nat
  title : String
  description : String
  completed : Bool
  createdAt : String
  updatedAt : String
  deriving Repr

structure State where
  nextUserId : Nat := 1
  nextTodoId : Nat := 1
  users : Array User := #[]
  sessions : Array (String × Nat) := #[] -- token -> userId
  todos : Array Todo := #[]
  deriving Inhabited

abbrev SafeState := IO.Ref State

namespace Util

def isWS (c : Char) : Bool :=
  c = ' ' || c = '\t' || c = '\r' || c = '\n'

def trimAscii (s : String) : String :=
  let rec dropFront (cs : List Char) : List Char :=
    match cs with | [] => [] | c::t => if isWS c then dropFront t else cs
  let rec dropBack (cs : List Char) : List Char :=
    match cs.reverse with
    | [] => []
    | c::t => if isWS c then dropBack t.reverse else cs
  String.ofList (dropBack (dropFront s.toList))

-- bytes to hex
def byteToHex (b : UInt8) : String :=
  let digits := "0123456789abcdef".toList
  let hi := digits.get! (Nat.ofUInt8 (b >>> 4))
  let lo := digits.get! (Nat.ofUInt8 (b &&& 0x0f))
  String.ofList [hi, lo]

end Util

namespace TimeUtil
open IO

-- Use external date for correct UTC ISO8601 with seconds
def isoNow : IO String := do
  let p ← IO.Process.spawn { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"], stdout := .piped }
  let s ← p.stdout.readToEnd
  let _ ← p.wait
  pure (Util.trimAscii s)

end TimeUtil

namespace HTTP

structure Request where
  method : String
  path : String
  headers : List (String × String)
  body : String
  deriving Repr

structure Response where
  status : Nat
  reason : String
  headers : List (String × String)
  body : String

namespace Response

def toBytes (r : Response) : ByteArray :=
  let statusLine := s!"HTTP/1.1 {r.status} {r.reason}\r\n"
  let hdrs := r.headers.map (fun (k,v) => s!"{k}: {v}\r\n").foldl (· ++ ·) ""
  let head := statusLine ++ hdrs ++ "\r\n"
  head.toUTF8 ++ r.body.toUTF8

end Response

-- Parse CRLF line terminated via Handle.getLine

private def parseHeader (line : String) : Option (String × String) :=
  match line.splitOn ":" with
  | [] => none
  | k::rest => some (Util.trimAscii k, Util.trimAscii (String.intercalate ":" rest))

private def findHeader (hs : List (String×String)) (name : String) : Option String :=
  let lname := name.toLower
  let rec go (hs : List (String×String)) :=
    match hs with
    | [] => none
    | (k,v)::t => if k.toLower = lname then some v else go t
  go hs

partial def readHttpRequest (h : IO.FS.Handle) : IO (Option Request) := do
  -- read request line
  let rl ← h.getLine
  if rl.isEmpty then return none
  let rlT := Util.trimAscii rl
  let parts := rlT.splitOn " "
  if parts.length < 2 then return none
  let method := parts[0]!
  let path := parts[1]!
  -- headers
  let rec readHeaders (acc : List (String×String)) : IO (List (String×String)) := do
    let l ← h.getLine
    let t := Util.trimAscii l
    if t = "" then return acc.reverse
    match parseHeader t with
    | some kv => readHeaders (kv :: acc)
    | none => readHeaders acc
  let headers ← readHeaders []
  -- body
  let body ← match findHeader headers "content-length" with
    | some v =>
      match v.toNat? with
      | some n =>
        let b ← h.read (USize.ofNat n)
        pure (String.fromUTF8Unchecked b)
      | none => pure ""
    | none => pure ""
  return some { method, path, headers, body }

end HTTP

namespace App
open HTTP Util TimeUtil

structure Ctx where
  state : SafeState
  writeH : IO.FS.Handle

-- Helpers

def reason (code : Nat) : String :=
  match code with
  | 200 => "OK" | 201 => "Created" | 204 => "No Content" | 400 => "Bad Request" | 401 => "Unauthorized" | 404 => "Not Found" | 409 => "Conflict" | _ => "Error"


def jsonError (code : Nat) (msg : String) : HTTP.Response :=
  let body := toString (Json.mkObj [("error", toJson msg)])
  { status := code, reason := reason code, headers := [("Content-Type","application/json"), ("Content-Length", toString body.toUTF8.size), ("Connection","close")], body := body }


def jsonOk (code : Nat) (j : Json) (extra : List (String×String) := []) : HTTP.Response :=
  let body := toString j
  { status := code, reason := reason code, headers := [("Content-Type","application/json"), ("Content-Length", toString body.toUTF8.size), ("Connection","close")] ++ extra, body := body }


def noContent204 : HTTP.Response :=
  { status := 204, reason := reason 204, headers := [("Connection","close")], body := "" }

-- Session helpers with Array

def sessionsFind (arr : Array (String×Nat)) (tok : String) : Option Nat :=
  let rec go (i : Nat) : Option Nat :=
    if h : i < arr.size then
      let (k,v) := arr.get ⟨i, h⟩
      if k = tok then some v else go (i+1)
    else none
  go 0

def sessionsErase (arr : Array (String×Nat)) (tok : String) : Array (String×Nat) :=
  let mut out := #[]
  for (k,v) in arr do
    if k ≠ tok then out := out.push (k,v)
  out

-- Users helpers

def findUserByUsername (st : State) (uname : String) : Option User :=
  let rec go (i : Nat) : Option User :=
    if h : i < st.users.size then
      let u := st.users.get ⟨i,h⟩
      if u.username = uname then some u else go (i+1)
    else none
  go 0


def findUserById (st : State) (uid : Nat) : Option User :=
  let rec go (i : Nat) : Option User :=
    if h : i < st.users.size then
      let u := st.users.get ⟨i,h⟩
      if u.id = uid then some u else go (i+1)
    else none
  go 0


def updateUser (st : State) (u : User) : State :=
  let mut arr := st.users
  for i in [0:arr.size] do
    if h : i < arr.size then
      let ui := arr.get ⟨i,h⟩
      if ui.id = u.id then
        arr := arr.set! i u
  { st with users := arr }

-- Cookie parsing

def findSessionUserId (st : State) (req : HTTP.Request) : Option Nat :=
  let cookie? := HTTP.findHeader req.headers "cookie"
  match cookie? with
  | none => none
  | some v =>
    let parts := v.splitOn ";"
    let mut tok? : Option String := none
    for p in parts do
      let kv := (Util.trimAscii p).splitOn "="
      if kv.length = 2 && Util.trimAscii kv[0]! = "session_id" then
        tok? := some (Util.trimAscii kv[1]!)
    match tok? with
    | none => none
    | some t => sessionsFind st.sessions t

-- Validation

def validUsername (u : String) : Bool :=
  let n := u.length
  if n < 3 || n > 50 then false
  else u.toList.all (fun c => c.isAlphanum || c = '_')

-- JSON helpers
partial def getJson (req : HTTP.Request) : Except String Json :=
  match Json.parse req.body with
  | .ok j => .ok j
  | .error e => .error s!"Invalid JSON: {e}"

def getStr? (j : Json) (k : String) : Option String :=
  match j.getObjVal? k with
  | .ok (Json.str s) => some s
  | _ => none

def getBool? (j : Json) (k : String) : Option Bool :=
  match j.getObjVal? k with
  | .ok (Json.bool b) => some b
  | _ => none

-- Handlers

def handleRegister (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let j := match getJson req with | .ok j => j | .error _ => return jsonError 400 "Invalid JSON"
  let some username := getStr? j "username" | return jsonError 400 "Invalid username"
  let some password := getStr? j "password" | return jsonError 400 "Password too short"
  if !validUsername username then return jsonError 400 "Invalid username"
  if password.length < 8 then return jsonError 400 "Password too short"
  let st ← ctx.state.get
  if (findUserByUsername st username).isSome then
    return jsonError 409 "Username already exists"
  let id := st.nextUserId
  let u : User := { id := id, username := username, password := password }
  let st' : State := { st with nextUserId := id + 1, users := st.users.push u }
  ctx.state.set st'
  return jsonOk 201 (Json.mkObj [("id", toJson id), ("username", toJson username)])


def handleLogin (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let j := match getJson req with | .ok j => j | .error _ => return jsonError 400 "Invalid JSON"
  let some username := getStr? j "username" | return jsonError 401 "Invalid credentials"
  let some password := getStr? j "password" | return jsonError 401 "Invalid credentials"
  let st ← ctx.state.get
  let some u := findUserByUsername st username | return jsonError 401 "Invalid credentials"
  if u.password ≠ password then return jsonError 401 "Invalid credentials"
  let bytes ← IO.getRandomBytes 16
  let token := bytes.data.foldl (fun acc b => acc ++ Util.byteToHex b) ""
  let st2 ← ctx.state.get
  ctx.state.set { st2 with sessions := st2.sessions.push (token, u.id) }
  let body := Json.mkObj [("id", toJson u.id), ("username", toJson u.username)]
  let extra := [("Set-Cookie", s!"session_id={token}; Path=/; HttpOnly")]
  return jsonOk 200 body extra


def requireAuth (ctx : Ctx) (req : HTTP.Request) : IO (Except HTTP.Response (Nat × User)) := do
  let st ← ctx.state.get
  let some uid := findSessionUserId st req | return .error (jsonError 401 "Authentication required")
  match findUserById st uid with
  | some u => return .ok (uid, u)
  | none => return .error (jsonError 401 "Authentication required")


def handleLogout (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let a ← requireAuth ctx req
  match a with
  | .error r => return r
  | .ok _ =>
    let some cookie := HTTP.findHeader req.headers "cookie" | return jsonOk 200 (Json.mkObj [])
    let mut token? : Option String := none
    for p in cookie.splitOn ";" do
      let kv := (Util.trimAscii p).splitOn "="
      if kv.length = 2 && Util.trimAscii kv[0]! = "session_id" then token? := some (Util.trimAscii kv[1]!)
    match token? with
    | none => return jsonOk 200 (Json.mkObj [])
    | some t =>
      let st ← ctx.state.get
      ctx.state.set { st with sessions := sessionsErase st.sessions t }
      return jsonOk 200 (Json.mkObj [])


def handleMe (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let a ← requireAuth ctx req
  match a with
  | .error r => return r
  | .ok (_, u) => return jsonOk 200 (Json.mkObj [("id", toJson u.id), ("username", toJson u.username)])


def handlePassword (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let a ← requireAuth ctx req
  match a with
  | .error r => return r
  | .ok (uid, u) =>
    let j := match getJson req with | .ok j => j | .error _ => return jsonError 400 "Invalid JSON"
    let some oldp := getStr? j "old_password" | return jsonError 401 "Invalid credentials"
    let some newp := getStr? j "new_password" | return jsonError 400 "Password too short"
    if u.password ≠ oldp then return jsonError 401 "Invalid credentials"
    if newp.length < 8 then return jsonError 400 "Password too short"
    let st ← ctx.state.get
    match findUserById st uid with
    | some u0 =>
      let st' := updateUser st { u0 with password := newp }
      ctx.state.set st'
      return jsonOk 200 (Json.mkObj [])
    | none => return jsonError 401 "Authentication required"


def todoToJson (t : Todo) : Json :=
  Json.mkObj [
    ("id", toJson t.id),
    ("title", toJson t.title),
    ("description", toJson t.description),
    ("completed", toJson t.completed),
    ("created_at", toJson t.createdAt),
    ("updated_at", toJson t.updatedAt)
  ]

-- Todos helpers

def findTodo (st : State) (id : Nat) : Option Todo :=
  let rec go (i : Nat) : Option Todo :=
    if h : i < st.todos.size then
      let t := st.todos.get ⟨i,h⟩
      if t.id = id then some t else go (i+1)
    else none
  go 0


def upsertTodo (st : State) (t : Todo) : State :=
  let mut arr := st.todos
  let mut found := false
  for i in [0:arr.size] do
    if h : i < arr.size then
      let ti := arr.get ⟨i,h⟩
      if ti.id = t.id then
        arr := arr.set! i t
        found := true
  let arr := if found then arr else arr.push t
  { st with todos := arr }


def eraseTodo (st : State) (id : Nat) : State :=
  let mut arr := #[]
  for t in st.todos do
    if t.id ≠ id then arr := arr.push t
  { st with todos := arr }


def handleTodosList (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let a ← requireAuth ctx req
  match a with
  | .error r => return r
  | .ok (uid, _) =>
    let st ← ctx.state.get
    let mut list : List Todo := []
    for t in st.todos do
      if t.userId = uid then list := t :: list
    let list := list.reverse
    let arr := list.map todoToJson |>.toArray
    return jsonOk 200 (Json.arr arr)


def handleTodosCreate (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let a ← requireAuth ctx req
  match a with
  | .error r => return r
  | .ok (uid, _) =>
    let j := match getJson req with | .ok j => j | .error _ => return jsonError 400 "Invalid JSON"
    let some title := getStr? j "title" | return jsonError 400 "Title is required"
    if Util.trimAscii title = "" then return jsonError 400 "Title is required"
    let desc := match getStr? j "description" with | some s => s | none => ""
    let now ← isoNow
    let st ← ctx.state.get
    let id := st.nextTodoId
    let t : Todo := { id := id, userId := uid, title := title, description := desc, completed := false, createdAt := now, updatedAt := now }
    let st' := { st with nextTodoId := id + 1, todos := st.todos.push t }
    ctx.state.set st'
    return jsonOk 201 (todoToJson t)


def parseIdFromPath (path : String) : Option Nat :=
  let ps := path.splitOn "/"
  if ps.length >= 3 then ps[2]!.toNat? else none


def handleTodosGet (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let a ← requireAuth ctx req
  match a with
  | .error r => return r
  | .ok (uid, _) =>
    let some id := parseIdFromPath req.path | return jsonError 404 "Todo not found"
    let st ← ctx.state.get
    match findTodo st id with
    | none => return jsonError 404 "Todo not found"
    | some t => if t.userId ≠ uid then return jsonError 404 "Todo not found" else return jsonOk 200 (todoToJson t)


def handleTodosUpdate (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let a ← requireAuth ctx req
  match a with
  | .error r => return r
  | .ok (uid, _) =>
    let some id := parseIdFromPath req.path | return jsonError 404 "Todo not found"
    let j := match getJson req with | .ok j => j | .error _ => return jsonError 400 "Invalid JSON"
    let st ← ctx.state.get
    match findTodo st id with
    | none => return jsonError 404 "Todo not found"
    | some t =>
      if t.userId ≠ uid then return jsonError 404 "Todo not found"
      if let some s := getStr? j "title" then
        if Util.trimAscii s = "" then return jsonError 400 "Title is required"
      let t1 := match getStr? j "title" with | some s => { t with title := s } | none => t
      let t2 := match getStr? j "description" with | some s => { t1 with description := s } | none => t1
      let t3 := match getBool? j "completed" with | some b => { t2 with completed := b } | none => t2
      let now ← isoNow
      let t' := { t3 with updatedAt := now }
      let st' := upsertTodo st t'
      ctx.state.set st'
      return jsonOk 200 (todoToJson t')


def handleTodosDelete (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  let a ← requireAuth ctx req
  match a with
  | .error r => return r
  | .ok (uid, _) =>
    let some id := parseIdFromPath req.path | return jsonError 404 "Todo not found"
    let st ← ctx.state.get
    match findTodo st id with
    | none => return jsonError 404 "Todo not found"
    | some t =>
      if t.userId ≠ uid then return jsonError 404 "Todo not found"
      let st' := eraseTodo st id
      ctx.state.set st'
      return noContent204


def route (ctx : Ctx) (req : HTTP.Request) : IO HTTP.Response := do
  match (req.method, req.path) with
  | ("POST", "/register") => handleRegister ctx req
  | ("POST", "/login") => handleLogin ctx req
  | ("POST", "/logout") => handleLogout ctx req
  | ("GET", "/me") => handleMe ctx req
  | ("PUT", "/password") => handlePassword ctx req
  | ("GET", "/todos") => handleTodosList ctx req
  | ("POST", "/todos") => handleTodosCreate ctx req
  | ("GET", p) => if p.startsWith "/todos/" then handleTodosGet ctx req else pure (jsonError 404 "Not found")
  | ("PUT", p) => if p.startsWith "/todos/" then handleTodosUpdate ctx req else pure (jsonError 404 "Not found")
  | ("DELETE", p) => if p.startsWith "/todos/" then handleTodosDelete ctx req else pure (jsonError 404 "Not found")
  | _ => pure (jsonError 404 "Not found")

end App

open App HTTP

-- args

def parseArgs (args : List String) : Nat :=
  match args with
  | "--port"::p::_ => p.toNat! | _ => 8080

-- run server using external nc as transport

def runServer (port : Nat) : IO Unit := do
  let proc ← IO.Process.spawn { cmd := "nc", args := #["-lk", "-p", toString port], stdin := .piped, stdout := .piped }
  let st ← IO.mkRef ({} : State)
  let ctx : App.Ctx := { state := st, writeH := proc.stdin }
  IO.println s!"Listening on 0.0.0.0:{port}"
  let hIn := proc.stdout
  let rec loop : IO Unit := do
    let req? ← HTTP.readHttpRequest hIn
    match req? with
    | none => IO.sleep 50 >> loop
    | some req =>
      let resp ← App.route ctx req
      let bytes := HTTP.Response.toBytes resp
      let _ ← ctx.writeH.write bytes
      ctx.writeH.flush
      loop
  loop


def main (args : List String) : IO Unit := do
  let port := parseArgs args
  runServer port
