import Std
import Std.Network.Socket
open Std
open Std.Network

/- Minimal HTTP types -/
structure HttpRequest where
  method : String
  path : String
  headers : List (String × String)
  body : ByteArray
  deriving Repr

structure HttpResponse where
  status : Nat
  statusText : String
  headers : List (String × String)
  body : ByteArray

namespace Http

def splitOnce (s : String) (sep : String) : Option (String × String) :=
  match s.splitOn sep with
  | a::b::rest => some (a, String.intercalate sep (b::rest))
  | _ => none

def parseRequest (rawHead : String) : HttpRequest :=
  let lines := rawHead.splitOn "\r\n"
  let (method, path) := match lines.head?.getD "" |>.splitOn " " with
    | m::p::_ => (m, p)
    | _ => ("", "")
  let rec loop (ls : List String) (hs : List (String × String)) :=
    match ls with
    | [] => hs
    | l::ls' =>
      if l = "" then hs.reverse
      else
        match splitOnce l ": " with
        | some (k,v) => loop ls' ((k,v)::hs)
        | none => loop ls' hs
  let hs := loop lines.tailD []
  { method := method, path := path, headers := hs, body := ByteArray.empty }

end Http

structure User where
  id : Nat
  username : String
  deriving Repr

structure Todo where
  id : Nat
  userId : Nat
  title : String
  description : String
  completed : Bool := false
  createdAt : String
  updatedAt : String
  deriving Repr

structure State where
  nextUserId : Nat := 1
  nextTodoId : Nat := 1
  usersByName : Std.HashMap String User := {}
  usersById : Std.HashMap Nat User := {}
  passwordById : Std.HashMap Nat String := {}
  sessions : Std.HashMap String Nat := {} -- token -> userId
  todos : Std.HashMap Nat Todo := {}
  deriving Inhabited

namespace Util

def nowIso8601 : IO String := do
  pure "1970-01-01T00:00:00Z"

def isAlnumUnderscore (s : String) : Bool :=
  s.data.all fun c => c.isAlphanum || c = '_'

def jsonStr (s : String) : String :=
  s!"\"{String.escape s}\""

def jsonKV (k v : String) := s!"{jsonStr k}: {v}"

def jsonObj (kvs : List (String × String)) : String :=
  let parts := kvs.map (fun (k,v) => jsonKV k v)
  s!"{{{String.intercalate ", " parts}}}"

def jsonArr (vals : List String) : String :=
  s!"[{String.intercalate ", " vals}]"

end Util

open Util
open Http

namespace Server

structure Ctx where
  st : IO.Ref State

-- Helpers

def getHeader? (req : HttpRequest) (name : String) : Option String :=
  req.headers.findSome? (fun (k,v) => if k.toLower = name.toLower then some v else none)

def getCookie? (req : HttpRequest) (name : String) : Option String :=
  match getHeader? req "Cookie" with
  | none => none
  | some cookieStr =>
    let parts := cookieStr.splitOn ";"
    let mut out := none
    for p in parts do
      let kv := p.trim
      if let some (k,v) := Http.splitOnce kv "=" then
        if k = name then out := some v
    out

def newToken : IO String := do
  let r1 ← IO.rand 0 UInt64.size
  let r2 ← IO.rand 0 UInt64.size
  pure (toString r1 ++ toString r2)

def userJson (u : User) : String :=
  jsonObj [ ("id", toString u.id), ("username", jsonStr u.username) ]

def todoJson (t : Todo) : String :=
  jsonObj [ ("id", toString t.id), ("title", jsonStr t.title), ("description", jsonStr t.description),
            ("completed", if t.completed then "true" else "false"),
            ("created_at", jsonStr t.createdAt), ("updated_at", jsonStr t.updatedAt) ]

def err (code : Nat) (msg : String) : HttpResponse :=
  { status := code, statusText := "Error",
    headers := [("Content-Type","application/json")],
    body := s!"{{\"error\": {jsonStr msg}}}" |>.toUTF8 }

def okJson (code : Nat) (body : String) : HttpResponse :=
  { status := code, statusText := "OK",
    headers := [("Content-Type","application/json")],
    body := body.toUTF8 }

def noContent : HttpResponse :=
  { status := 204, statusText := "No Content", headers := [], body := ByteArray.empty }

-- Very naive JSON parsing for simple flat objects
partial def parseJsonObj (s : String) : Std.HashMap String String :=
  let s := s.trim
  if !s.startsWith "{" || !s.endsWith "}" then return {}
  let inner := s.drop 1 |>.dropRight 1
  let parts := inner.splitOn ","
  let mut m : Std.HashMap String String := {}
  for p in parts do
    let pp := p.trim
    if let some (k,v) := Http.splitOnce pp ":" then
      let k := k.trim.trimLeft '"' |>.trimRight '"'
      m := m.insert k (v.trim)
  m

-- auth helper
def withAuth (ctx : Ctx) (req : HttpRequest) : IO (Except HttpResponse Nat) := do
  let some tok := getCookie? req "session_id"
    | return .error (err 401 "Authentication required")
  let st ← ctx.st.get
  match st.sessions.find? tok with
  | some uid => return .ok uid
  | none => return .error (err 401 "Authentication required")

-- Handlers

def handleRegister (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  let body := String.fromUTF8Unchecked req.body
  let m := parseJsonObj body
  let some u := m.find? "username" | return err 400 "Invalid username"
  let some p := m.find? "password" | return err 400 "Password too short"
  let username := u.trim.trimLeft '"' |>.trimRight '"'
  let password := p.trim.trimLeft '"' |>.trimRight '"'
  if username.length < 3 || username.length > 50 || !Util.isAlnumUnderscore username then
    return err 400 "Invalid username"
  if password.length < 8 then
    return err 400 "Password too short"
  let st ← ctx.st.get
  if st.usersByName.contains username then
    return err 409 "Username already exists"
  let uid := st.nextUserId
  let user : User := { id := uid, username := username }
  let st' := { st with
    nextUserId := uid + 1,
    usersByName := st.usersByName.insert username user,
    usersById := st.usersById.insert uid user,
    passwordById := st.passwordById.insert uid password
  }
  ctx.st.set st'
  return okJson 201 (userJson user)


def handleLogin (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  let body := String.fromUTF8Unchecked req.body
  let m := parseJsonObj body
  let some u := m.find? "username" | return err 401 "Invalid credentials"
  let some p := m.find? "password" | return err 401 "Invalid credentials"
  let username := u.trim.trimLeft '"' |>.trimRight '"'
  let password := p.trim.trimLeft '"' |>.trimRight '"'
  let st ← ctx.st.get
  match st.usersByName.find? username with
  | none => return err 401 "Invalid credentials"
  | some user =>
    match st.passwordById.find? user.id with
    | some pw =>
      if pw = password then
        let token ← newToken
        let st2 := { st with sessions := st.sessions.insert token user.id }
        ctx.st.set st2
        let resp := okJson 200 (userJson user)
        let hdrs := [("Content-Type","application/json"), ("Set-Cookie", s!"session_id={token}; Path=/; HttpOnly")]
        return { resp with headers := hdrs }
      else return err 401 "Invalid credentials"
    | none => return err 401 "Invalid credentials"


def handleLogout (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match ← withAuth ctx req with
  | .error r => return r
  | .ok _uid =>
    let some tok := getCookie? req "session_id" | return err 401 "Authentication required"
    let st ← ctx.st.get
    ctx.st.set { st with sessions := st.sessions.erase tok }
    return okJson 200 (jsonObj [])


def handleMe (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match ← withAuth ctx req with
  | .error r => return r
  | .ok uid =>
    let st ← ctx.st.get
    match st.usersById.find? uid with
    | some u => return okJson 200 (userJson u)
    | none => return err 401 "Authentication required"


def handlePassword (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match ← withAuth ctx req with
  | .error r => return r
  | .ok uid =>
    let body := String.fromUTF8Unchecked req.body
    let m := parseJsonObj body
    let some oldv := m.find? "old_password" | return err 401 "Invalid credentials"
    let some newv := m.find? "new_password" | return err 400 "Password too short"
    let oldp := oldv.trim.trimLeft '"' |>.trimRight '"'
    let newp := newv.trim.trimLeft '"' |>.trimRight '"'
    if newp.length < 8 then return err 400 "Password too short"
    let st ← ctx.st.get
    match st.passwordById.find? uid with
    | some cur =>
      if cur ≠ oldp then return err 401 "Invalid credentials"
      else
        ctx.st.set { st with passwordById := st.passwordById.insert uid newp }
        return okJson 200 (jsonObj [])
    | none => return err 401 "Invalid credentials"


def findUserTodo (ctx : Ctx) (uid : Nat) (tid : Nat) : IO (Except HttpResponse Todo) := do
  let st ← ctx.st.get
  match st.todos.find? tid with
  | none => return .error (err 404 "Todo not found")
  | some t => if t.userId = uid then return .ok t else return .error (err 404 "Todo not found")


def handleTodosList (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match ← withAuth ctx req with
  | .error r => return r
  | .ok uid =>
    let st ← ctx.st.get
    let mut arr : List String := []
    let mut ids := st.todos.toList.map (fun (k,_) => k)
    ids := ids.qsort (· ≤ ·)
    for id in ids do
      match st.todos.find? id with
      | some t => if t.userId = uid then arr := arr.concat (todoJson t) else pure ()
      | none => pure ()
    return okJson 200 (jsonArr arr)


def handleTodosCreate (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match ← withAuth ctx req with
  | .error r => return r
  | .ok uid =>
    let body := String.fromUTF8Unchecked req.body
    let m := parseJsonObj body
    let title := (m.findD "title" "\"\" ").trim.trimLeft '"' |>.trimRight '"'
    if title = "" then return err 400 "Title is required"
    let desc := match m.find? "description" with
      | some v => v.trim.trimLeft '"' |>.trimRight '"'
      | none => ""
    let ts ← nowIso8601
    let st ← ctx.st.get
    let id := st.nextTodoId
    let todo : Todo := { id := id, userId := uid, title := title, description := desc, completed := false, createdAt := ts, updatedAt := ts }
    ctx.st.set { st with nextTodoId := id + 1, todos := st.todos.insert id todo }
    return okJson 201 (todoJson todo)


def parseIdFromPath (path : String) : Option Nat :=
  -- paths like /todos/123
  match path.splitOn "/" with
  | _::"todos"::idStr::_ => idStr.toNat?
  | _ => none


def handleTodoGet (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match ← withAuth ctx req with
  | .error r => return r
  | .ok uid =>
    let some tid := parseIdFromPath req.path | return err 404 "Todo not found"
    match ← findUserTodo ctx uid tid with
    | .ok t => return okJson 200 (todoJson t)
    | .error r => return r


def handleTodoUpdate (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match ← withAuth ctx req with
  | .error r => return r
  | .ok uid =>
    let some tid := parseIdFromPath req.path | return err 404 "Todo not found"
    let body := String.fromUTF8Unchecked req.body
    let m := parseJsonObj body
    let st ← ctx.st.get
    match st.todos.find? tid with
    | none => return err 404 "Todo not found"
    | some t =>
      if t.userId ≠ uid then return err 404 "Todo not found"
      let mut t := t
      if let some v := m.find? "title" then
        let tv := v.trim.trimLeft '"' |>.trimRight '"'
        if tv = "" then return err 400 "Title is required" else t := { t with title := tv }
      if let some v := m.find? "description" then
        t := { t with description := v.trim.trimLeft '"' |>.trimRight '"' }
      if let some v := m.find? "completed" then
        let b := v.trim
        let bv := if b = "true" then true else if b = "false" then false else t.completed
        t := { t with completed := bv }
      let ts ← nowIso8601
      t := { t with updatedAt := ts }
      ctx.st.set { st with todos := st.todos.insert tid t }
      return okJson 200 (todoJson t)


def handleTodoDelete (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match ← withAuth ctx req with
  | .error r => return r
  | .ok uid =>
    let some tid := parseIdFromPath req.path | return err 404 "Todo not found"
    let st ← ctx.st.get
    match st.todos.find? tid with
    | none => return err 404 "Todo not found"
    | some t =>
      if t.userId ≠ uid then return err 404 "Todo not found"
      ctx.st.set { st with todos := st.todos.erase tid }
      return noContent


def route (ctx : Ctx) (req : HttpRequest) : IO HttpResponse := do
  match req.method, req.path with
  | "POST", "/register" => handleRegister ctx req
  | "POST", "/login" => handleLogin ctx req
  | "POST", "/logout" => handleLogout ctx req
  | "GET", "/me" => handleMe ctx req
  | "PUT", "/password" => handlePassword ctx req
  | "GET", "/todos" => handleTodosList ctx req
  | "POST", "/todos" => handleTodosCreate ctx req
  | "GET", p => if p.startsWith "/todos/" then handleTodoGet ctx req else return err 404 "Not found"
  | "PUT", p => if p.startsWith "/todos/" then handleTodoUpdate ctx req else return err 404 "Not found"
  | "DELETE", p => if p.startsWith "/todos/" then handleTodoDelete ctx req else return err 404 "Not found"
  | _, _ => return err 404 "Not found"

-- Build raw HTTP string from response, ensuring Content-Length and Connection: close.

def responseToString (rIn : HttpResponse) : String :=
  let body := rIn.body
  let baseHeaders := rIn.headers
  let headers :=
    baseHeaders
      |>.filter (fun (k,_) => k.toLower ≠ "content-length" && k.toLower ≠ "connection")
      |>.append [("Content-Length", toString body.size), ("Connection","close")]
  let start := s!"HTTP/1.1 {rIn.status} {rIn.statusText}\r\n"
  let hdrs := headers.map (fun (k,v) => s!"{k}: {v}") |> String.intercalate "\r\n"
  let endh := "\r\n\r\n"
  start ++ hdrs ++ endh ++ String.fromUTF8Unchecked body

-- Socket IO helpers

def readUntilDoubleCRLF (h : IO.FS.Handle) : IO String := do
  let mut buf : ByteArray := ByteArray.empty
  let mut found := false
  while !found do
    let chunk ← h.read 1024
    if chunk.isEmpty then break
    buf := buf ++ chunk
    let s := String.fromUTF8Unchecked buf
    if s.contains "\r\n\r\n" then
      found := true
  pure (String.fromUTF8Unchecked buf)


def readBody (reqStr : String) (h : IO.FS.Handle) : IO ByteArray := do
  let headersPart := reqStr.splitOn "\r\n\r\n" |>.headD ""
  let lines := headersPart.splitOn "\r\n"
  let mut clen : Nat := 0
  for l in lines do
    if let some (k,v) := Http.splitOnce l ": " then
      if k.toLower = "content-length" then
        match v.toNat? with
        | some n => clen := n
        | none => pure ()
  let after := reqStr.splitOn "\r\n\r\n"
  let firstBody := String.intercalate "\r\n\r\n" after.drop 1
  let mut bodyBA := firstBody.toUTF8
  let remaining := if clen > bodyBA.size then clen - bodyBA.size else 0
  if remaining > 0 then
    let more ← h.read remaining
    bodyBA := bodyBA ++ more
  pure bodyBA


def serve (port : UInt16) : IO Unit := do
  let srv ← Socket.mk .inet
  srv.setOptBool SocketOption.reuseAddr true
  srv.bind { family := .inet, addr := .v4 0 0 0 0, port := port }
  srv.listen 128
  IO.println s!"Listening on 0.0.0.0:{port}"
  let stRef ← IO.mkRef (default : State)
  let ctx : Ctx := { st := stRef }
  let rec loop : IO Unit := do
    let (sock, _peer) ← srv.accept
    let h ← sock.toHandle
    let reqHead ← readUntilDoubleCRLF h
    let body ← readBody reqHead h
    let req := (Http.parseRequest reqHead)
    let req := { req with body := body }
    let resp ← route ctx req
    let resp := if resp.status = 204 then { resp with headers := resp.headers.filter (fun (k,_) => k.toLower ≠ "content-type"), body := ByteArray.empty } else resp
    let out := responseToString resp
    let _ ← sock.send out.toUTF8
    h.close
    sock.close
    loop
  loop

end Server

open Server

def parseArgs (args : List String) : Option UInt16 :=
  match args with
  | "--port"::p::_ =>
    match p.toNat? with
    | some n => if h : n ≤ UInt16.max.toNat then some (UInt16.ofNat n) else none
    | none => none
  | _ => none

def main (args : List String) : IO UInt32 := do
  match parseArgs args with
  | some p => Server.serve p; pure 0
  | none =>
    IO.eprintln "Usage: todo --port PORT"
    pure 1
