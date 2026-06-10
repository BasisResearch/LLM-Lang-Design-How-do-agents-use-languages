import Lean.Data.Json
import Lean.Data.Json.FromToJson
open Lean

structure User where
  id : Nat
  username : String
  password : String
  deriving BEq

structure Todo where
  id : Nat
  userId : Nat
  title : String
  description : String
  completed : Bool := false
  createdAt : String
  updatedAt : String
  deriving BEq

structure AppState where
  nextUserId : Nat := 1
  nextTodoId : Nat := 1
  users : List User := []
  sessions : List (String × Nat) := []
  todos : List Todo := []
  timeCounter : Nat := 0
  deriving Inhabited

abbrev M := StateT AppState IO

namespace Util

private def hexDigit (n : Nat) : Char :=
  let d := n % 16
  if d < 10 then Char.ofNat (48 + d) else Char.ofNat (87 + d)

def genToken : IO String := do
  let mut s := ""
  for _ in [0:32] do
    let n ← IO.rand 0 15
    s := s.push (hexDigit n)
  return s

private def pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else toString n

def isoFromSec (baseDate : String) (sec : Nat) : String :=
  let secDay := sec % 86400
  let hh := secDay / 3600
  let mm := (secDay % 3600) / 60
  let ss := secDay % 60
  s!"{baseDate}T{pad2 hh}:{pad2 mm}:{pad2 ss}Z"

end Util

namespace HTTP

structure Request where
  method : String
  path : String
  headers : List (String × String)
  body : String

structure Response where
  status : Nat
  headers : List (String × String)
  body : String

private def headerLine (k v : String) : String := s!"{k}: {v}\r\n"

def reason (code : Nat) : String :=
  match code with
  | 200 => "OK"
  | 201 => "Created"
  | 204 => "No Content"
  | 400 => "Bad Request"
  | 401 => "Unauthorized"
  | 404 => "Not Found"
  | 409 => "Conflict"
  | _ => "OK"

def serialize (r : Response) : String :=
  let statusLine := s!"HTTP/1.1 {r.status} {reason r.status}\r\n"
  let hdrs := r.headers.foldl (fun acc (k,v) => acc ++ headerLine k v) ""
  let body := r.body
  let hdrs :=
    (if r.status == 204 then hdrs else hdrs ++ s!"Content-Type: application/json\r\n") ++
    s!"Content-Length: {body.toUTF8.size}\r\nConnection: close\r\n"
  statusLine ++ hdrs ++ "\r\n" ++ body

private def parseHeaders (lines : List String) : List (String × String) :=
  let rec go (ls : List String) (acc : List (String × String)) :=
    match ls with
    | [] => acc.reverse
    | l :: ls' =>
      if l.isEmpty then go ls' acc else
      let parts := l.splitOn ":"
      match parts with
      | [] => go ls' acc
      | k :: rest =>
        let v := String.intercalate ":" rest |>.trim
        go ls' ((k.trim, v) :: acc)
  go lines []

def parseRequestFromString (raw : String) : Option Request :=
  let pieces := raw.splitOn "\r\n\r\n"
  if pieces.isEmpty then none else
  let head := pieces.get! 0
  let body := if pieces.length ≥ 2 then String.intercalate "\r\n\r\n" (pieces.drop 1) else ""
  let lines := head.splitOn "\r\n"
  match lines with
  | [] => none
  | requestLine :: hdrLines =>
    let segs := requestLine.splitOn " "
    match segs with
    | method :: path :: _ =>
      some { method, path, headers := parseHeaders hdrLines, body }
    | _ => none

def header (req : Request) (name : String) : Option String :=
  let lname := name.toLower
  let rec go (xs : List (String × String)) :=
    match xs with
    | [] => none
    | (k,v) :: ys => if k.toLower == lname then some v else go ys
  go req.headers

def cookie (req : Request) (name : String) : Option String := do
  let c ← header req "Cookie"
  let parts := c.splitOn ";"
  let kvs := parts.map (fun p => p.trim)
  let rec find (l : List String) : Option String :=
    match l with
    | [] => none
    | p::ps =>
      let kv := p.splitOn "="
      match kv with
      | k::rest => if k == name then some (String.intercalate "=" rest) else find ps
      | _ => find ps
  find kvs

end HTTP

open HTTP
open Util

namespace App

private def liftIO {σ α} (io : IO α) : StateT σ IO α := fun s => do let a ← io; pure (a, s)

private def jsonError (msg : String) : String := toString <| Json.render <| Json.mkObj [("error", Json.str msg)]
private def respJson (code : Nat) (bodyObj : Json) : Response := { status := code, headers := [], body := toString <| Json.render bodyObj }
private def respJsonRaw (code : Nat) (body : String) : Response := { status := code, headers := [], body }
private def unauthorized : Response := respJsonRaw 401 (jsonError "Authentication required")
private def invalidCreds : Response := respJsonRaw 401 (jsonError "Invalid credentials")
private def notFoundTodo : Response := respJsonRaw 404 (jsonError "Todo not found")

private def validateUsername (u : String) : Bool :=
  let n := u.length
  if n < 3 ∨ n > 50 then false else u.toList.all (fun c => c.isAlphanum ∨ c = '_')

private def nextTimestamp : StateT AppState IO String := do
  let st ← get
  let sec := st.timeCounter
  let ts := Util.isoFromSec "2025-01-01" sec
  set { st with timeCounter := st.timeCounter + 1 }
  return ts

structure LoginReq where
  username : String
  password : String
  deriving FromJson
abbrev RegisterReq := LoginReq
structure PasswordReq where
  old_password : String
  new_password : String
  deriving FromJson
structure TodoCreateReq where
  title : String
  description : Option String := none
  deriving FromJson
structure TodoUpdateReq where
  title : Option String := none
  description : Option String := none
  completed : Option Bool := none
  deriving FromJson

private def parseJsonAs (α : Type) [FromJson α] (body : String) : Option α :=
  match Json.parse body with
  | Except.ok j => (fromJson? j).toOption
  | Except.error _ => none

private def jsonUser (u : User) : Json := Json.mkObj [("id", Json.num u.id), ("username", Json.str u.username)]
private def jsonTodo (t : Todo) : Json :=
  Json.mkObj [ ("id", Json.num t.id), ("title", Json.str t.title), ("description", Json.str t.description), ("completed", Json.bool t.completed), ("created_at", Json.str t.createdAt), ("updated_at", Json.str t.updatedAt) ]

-- List-based state helpers
private def findUserByUsername (st : AppState) (name : String) : Option User :=
  let rec go (xs : List User) := match xs with | [] => none | u::us => if u.username == name then some u else go us; go st.users
private def findUserById (st : AppState) (uid : Nat) : Option User :=
  let rec go (xs : List User) := match xs with | [] => none | u::us => if u.id == uid then some u else go us; go st.users
private def upsertUser (st : AppState) (u : User) : AppState :=
  let rec go (xs : List User) : List User := match xs with | [] => [u] | x::xs => if x.id == u.id then u::xs else x :: go xs
  { st with users := go st.users }
private def sessionLookup (st : AppState) (sid : String) : Option Nat :=
  let rec go (xs : List (String × Nat)) := match xs with | [] => none | (k,v)::xs => if k == sid then some v else go xs; go st.sessions
private def sessionInsert (st : AppState) (sid : String) (uid : Nat) : AppState :=
  let rec go (xs : List (String × Nat)) : List (String × Nat) := match xs with | [] => [(sid,uid)] | (k,v)::xs => if k == sid then (sid,uid)::xs else (k,v)::go xs
  { st with sessions := go st.sessions }
private def sessionErase (st : AppState) (sid : String) : AppState :=
  let rec go (xs : List (String × Nat)) : List (String × Nat) := match xs with | [] => [] | (k,v)::xs => if k == sid then xs else (k,v)::go xs
  { st with sessions := go st.sessions }
private def todoFind (st : AppState) (tid : Nat) : Option Todo :=
  let rec go (xs : List Todo) := match xs with | [] => none | t::ts => if t.id == tid then some t else go ts; go st.todos
private def todoUpsert (st : AppState) (t : Todo) : AppState :=
  let rec go (xs : List Todo) : List Todo := match xs with | [] => [t] | x::xs => if x.id == t.id then t::xs else x::go xs
  { st with todos := go st.todos }
private def todoErase (st : AppState) (tid : Nat) : AppState :=
  let rec go (xs : List Todo) : List Todo := match xs with | [] => [] | x::xs => if x.id == tid then xs else x::go xs
  { st with todos := go st.todos }
private def sortById (xs : List Todo) : List Todo :=
  let rec insert (t : Todo) (ys : List Todo) : List Todo := match ys with | [] => [t] | y::ys' => if t.id ≤ y.id then t::y::ys' else y::insert t ys'
  let rec go (xs : List Todo) (acc : List Todo) : List Todo := match xs with | [] => acc | z::zs => go zs (insert z acc)
  go xs []
private def todosForUser (st : AppState) (uid : Nat) : List Todo :=
  let rec go (xs : List Todo) (acc : List Todo) := match xs with | [] => acc | t::ts => if t.userId == uid then go ts (t::acc) else go ts acc
  sortById (go st.todos [])

private def withAuth (req : Request) : StateT AppState IO (Option User) := do
  let sid? := HTTP.cookie req "session_id"
  match sid? with
  | none => return none
  | some sid => do
    let st ← get
    match sessionLookup st sid with
    | none => return none
    | some uid => return findUserById st uid

private def handleRegister (body : String) : M Response := do
  match parseJsonAs (RegisterReq) body with
  | none => return respJsonRaw 400 (jsonError "Invalid JSON")
  | some req => do
    if !validateUsername req.username then return respJsonRaw 400 (jsonError "Invalid username")
    if req.password.length < 8 then return respJsonRaw 400 (jsonError "Password too short")
    let st ← get
    if (findUserByUsername st req.username).isSome then return respJsonRaw 409 (jsonError "Username already exists")
    let id := st.nextUserId
    let u : User := { id, username := req.username, password := req.password }
    set { (upsertUser st u) with nextUserId := id + 1 }
    return respJson 201 (jsonUser u)

private def handleLogin (body : String) : M Response := do
  match parseJsonAs (LoginReq) body with
  | none => return respJsonRaw 400 (jsonError "Invalid JSON")
  | some req => do
    let st ← get
    match findUserByUsername st req.username with
    | none => return invalidCreds
    | some u =>
      if u.password != req.password then return invalidCreds
      let tok ← liftIO Util.genToken
      set (sessionInsert st tok u.id)
      let r := respJson 200 (jsonUser u)
      let r := { r with headers := [("Set-Cookie", s!"session_id={tok}; Path=/; HttpOnly")] }
      return r

private def handleLogout (req : Request) : M Response := do
  let sid? := HTTP.cookie req "session_id"
  match sid? with
  | none => return unauthorized
  | some sid => do
    let st ← get
    match sessionLookup st sid with
    | none => return unauthorized
    | some _ => set (sessionErase st sid); return respJson 200 (Json.mkObj [])

private def handleMe (req : Request) : M Response := do
  let u? ← withAuth req; match u? with | none => return unauthorized | some u => return respJson 200 (jsonUser u)

private def handlePassword (req : Request) (body : String) : M Response := do
  let u? ← withAuth req
  match u? with
  | none => return unauthorized
  | some u =>
    match parseJsonAs (PasswordReq) body with
    | none => return respJsonRaw 400 (jsonError "Invalid JSON")
    | some pr => do
      if pr.old_password != u.password then return invalidCreds
      if pr.new_password.length < 8 then return respJsonRaw 400 (jsonError "Password too short")
      let st ← get
      let u' := { u with password := pr.new_password }
      set (upsertUser st u')
      return respJson 200 (Json.mkObj [])

private def handleTodosGet (req : Request) : M Response := do
  let u? ← withAuth req; match u? with
  | none => return unauthorized
  | some u => do
    let st ← get
    let arr := todosForUser st u.id
    let js := Json.arr <| (arr.map jsonTodo).toArray
    return respJson 200 js

private def nextId (st : AppState) : Nat := st.nextTodoId

private def handleTodosPost (req : Request) (body : String) : M Response := do
  let u? ← withAuth req
  match u? with
  | none => return unauthorized
  | some u =>
    match parseJsonAs (TodoCreateReq) body with
    | none => return respJsonRaw 400 (jsonError "Invalid JSON")
    | some cr => do
      if cr.title.isEmpty then return respJsonRaw 400 (jsonError "Title is required")
      let st ← get
      let id := st.nextTodoId
      let ts ← nextTimestamp
      let t : Todo := { id, userId := u.id, title := cr.title, description := cr.description.getD "", completed := false, createdAt := ts, updatedAt := ts }
      set { (todoUpsert st t) with nextTodoId := id + 1 }
      return respJson 201 (jsonTodo t)

private def parseId (path : String) : Option Nat :=
  let parts := path.splitOn "/"
  match parts with
  | _ :: "todos" :: sid :: [] => sid.toNat?
  | _ => none

private def getTodoOwned (id : Nat) (uid : Nat) : StateT AppState IO (Option Todo) := do
  let st ← get
  match todoFind st id with
  | none => return none
  | some t => if t.userId == uid then return some t else return none

private def handleTodoGet (req : Request) : M Response := do
  let u? ← withAuth req
  match u? with
  | none => return unauthorized
  | some u =>
    match parseId req.path with
    | none => return respJsonRaw 404 (jsonError "Not Found")
    | some id => do
      let t? ← getTodoOwned id u.id
      match t? with | none => return notFoundTodo | some t => return respJson 200 (jsonTodo t)

private def handleTodoPut (req : Request) (body : String) : M Response := do
  let u? ← withAuth req
  match u? with
  | none => return unauthorized
  | some u =>
    match parseId req.path with
    | none => return respJsonRaw 404 (jsonError "Not Found")
    | some id => do
      let t? ← getTodoOwned id u.id
      match t? with
      | none => return notFoundTodo
      | some t =>
        match parseJsonAs (TodoUpdateReq) body with
        | none => return respJsonRaw 400 (jsonError "Invalid JSON")
        | some upd => do
          let mut t' := t
          match upd.title with | some s => if s.isEmpty then return respJsonRaw 400 (jsonError "Title is required") else t' := { t' with title := s } | none => pure ()
          match upd.description with | some s => t' := { t' with description := s } | none => pure ()
          match upd.completed with | some b => t' := { t' with completed := b } | none => pure ()
          let ts ← nextTimestamp; t' := { t' with updatedAt := ts }
          let st ← get; set (todoUpsert st t'); return respJson 200 (jsonTodo t')

private def handleTodoDelete (req : Request) : M Response := do
  let u? ← withAuth req
  match u? with
  | none => return unauthorized
  | some u =>
    match parseId req.path with
    | none => return respJsonRaw 404 (jsonError "Not Found")
    | some id => do
      let t? ← getTodoOwned id u.id
      match t? with | none => return notFoundTodo | some _ => let st ← get; set (todoErase st id); return { status := 204, headers := [], body := "" }

private def handle (req : Request) : M Response := do
  match (req.method, req.path) with
  | ("POST","/register") => handleRegister req.body
  | ("POST","/login") => handleLogin req.body
  | ("POST","/logout") => handleLogout req
  | ("GET","/me") => handleMe req
  | ("PUT","/password") => handlePassword req req.body
  | ("GET","/todos") => handleTodosGet req
  | ("POST","/todos") => handleTodosPost req req.body
  | ("GET", p) => if p.startsWith "/todos/" then handleTodoGet req else return respJsonRaw 404 (jsonError "Not Found")
  | ("PUT", p) => if p.startsWith "/todos/" then handleTodoPut req req.body else return respJsonRaw 404 (jsonError "Not Found")
  | ("DELETE", p) => if p.startsWith "/todos/" then handleTodoDelete req else return respJsonRaw 404 (jsonError "Not Found")
  | _ => return respJsonRaw 404 (jsonError "Not Found")

end App

open App

structure Args where
  port : Nat := 8080
  ipcDir : String := "./ipc"

private def parseArgs (argv : List String) : Args :=
  let rec go (a : Args) (xs : List String) : Args :=
    match xs with
    | [] => a
    | "--port" :: p :: rest => match p.toNat? with | some n => go { a with port := n } rest | none => go a rest
    | "--ipc" :: d :: rest => go { a with ipcDir := d } rest
    | _ :: rest => go a rest
  go {} argv

private def processOne (stRef : IO.Ref AppState) (ipcDir : String) (id : String) (reqPath : String) : IO Unit := do
  let ba ← IO.FS.readFile reqPath
  let raw := String.fromUTF8! ba
  match HTTP.parseRequestFromString raw with
  | none =>
    let r : HTTP.Response := { status := 400, headers := [], body := toString <| Json.render <| Json.mkObj [("error", Json.str "Invalid Request")] }
    let resp := HTTP.serialize r
    let respPath := s!"{ipcDir}/resp-{id}.out"
    IO.FS.withFile respPath .write fun h => h.putStr resp
  | some req => do
    let st ← stRef.get
    let (resp, st') ← (App.handle req).run st
    stRef.set st'
    let mut respStr := HTTP.serialize resp
    -- add Set-Cookie if present in headers
    if resp.headers.any (fun (k,_) => k == "Set-Cookie") then
      -- serialize already includes headers; they were in headers list and Content-Type added in serializer for non-204
      pure ()
    let respPath := s!"{ipcDir}/resp-{id}.out"
    IO.FS.withFile respPath .write fun h => h.putStr respStr

private def workerLoop (stRef : IO.Ref AppState) (ipcDir : String) : IO Unit := do
  let fifo := s!"{ipcDir}/queue.fifo"
  -- Open and read lines forever
  let h ← IO.FS.Handle.mk fifo .read
  let rec loop : IO Unit := do
    let line ← h.getLine
    if line.isEmpty then
      IO.sleep 10
      loop
    else
      let trimmed := line.trim
      if trimmed.isEmpty then loop else
      let parts := trimmed.splitOn " "
      let id := if parts.length ≥ 1 then parts.get! 0 else ""
      let path := if parts.length ≥ 2 then parts.get! 1 else ""
      if id == "" ∨ path == "" then loop else
      (processOne stRef ipcDir id path) `catch` (fun _ => pure ())
      loop
  loop

def main (argv : List String) : IO UInt32 := do
  let args := parseArgs argv
  let stRef ← IO.mkRef ({} : AppState)
  -- run worker loop processing requests from FIFO
  workerLoop stRef args.ipcDir
  return 0
