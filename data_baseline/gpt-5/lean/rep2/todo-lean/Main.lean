import Lean
open IO

namespace Simple

structure Map (K V) where
  data : List (K × V) := []
  deriving Inhabited

namespace Map
variable [DecidableEq K]

def find? (m : Map K V) (k : K) : Option V :=
  match m.data.find? (fun (p : K × V) => p.fst = k) with
  | none => none
  | some p => some p.snd

def insert (m : Map K V) (k : K) (v : V) : Map K V :=
  let filtered := m.data.filter (fun p => p.fst ≠ k)
  { data := (k, v) :: filtered }

def erase (m : Map K V) (k : K) : Map K V :=
  { data := m.data.filter (fun p => p.fst ≠ k) }

def contains (m : Map K V) (k : K) : Bool := (find? m k).isSome

def findD (m : Map K V) (k : K) (d : V) : V := (find? m k).getD d

end Map

end Simple

namespace Todo

abbrev Map := Simple.Map
abbrev MapF (K V) := Simple.Map K V

instance : DecidableEq Nat := inferInstance
instance : DecidableEq String := inferInstance

deriving instance Repr for ByteArray

structure User where
  id : Nat
  username : String
  deriving Repr, BEq

structure UserRecord where
  id : Nat
  username : String
  password : String
  deriving Repr

structure TodoItem where
  id : Nat
  ownerId : Nat
  title : String
  description : String
  completed : Bool
  created_at : String
  updated_at : String
  deriving Repr

namespace TodoItem
  def toJsonObj (t : TodoItem) : Lean.Json :=
    Lean.Json.mkObj [
      ("id", Lean.Json.num t.id)
    , ("title", Lean.Json.str t.title)
    , ("description", Lean.Json.str t.description)
    , ("completed", Lean.Json.bool t.completed)
    , ("created_at", Lean.Json.str t.created_at)
    , ("updated_at", Lean.Json.str t.updated_at)
    ]
end TodoItem

structure AppState where
  nextUserId : Nat := 1
  nextTodoId : Nat := 1
  usersByName : MapF String UserRecord := {}
  usersById : MapF Nat UserRecord := {}
  sessions : MapF String Nat := {}
  todosById : MapF Nat TodoItem := {}
  userTodoIds : MapF Nat (List Nat) := {}
  deriving Inhabited

abbrev SharedState := IO.Ref AppState

-- Helpers

def isValidUsername (u : String) : Bool :=
  let n := u.length
  let goodLen := n >= 3 && n <= 50
  let goodChars := u.toList.all fun c => c.isAlphanum || c == '_'
  goodLen && goodChars

def nowIsoUtc : IO String := do
  let out ← IO.Process.output { cmd := "date", args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] }
  pure out.stdout.trim

def newSessionToken : IO String := do
  try
    let s ← FS.readFile "/proc/sys/kernel/random/uuid"
    pure <| (s.trim.replace "-" "")
  catch _ =>
    let t ← nowIsoUtc
    pure ("tok_" ++ t)

structure Request where
  method : String
  path : String
  version : String
  headers : List (String × String)
  body : ByteArray
  deriving Repr

structure Response where
  status : Nat
  reason : String
  headers : Array (String × String)
  body : ByteArray

-- JSON helpers

def jsonError (msg : String) : Lean.Json := Lean.Json.mkObj [("error", Lean.Json.str msg)]

def encodeJson (j : Lean.Json) : ByteArray := j.compress.toUTF8

-- Headers and cookies

def headerLookup (hdrs : List (String × String)) (key : String) : Option String :=
  let keyL := key.toLower
  match hdrs.find? (fun (p : String × String) => p.fst.toLower = keyL) with
  | some p => some p.snd
  | none => none

def parseCookies (hdrs : List (String × String)) : List (String × String) :=
  match headerLookup hdrs "cookie" with
  | none => []
  | some v =>
    let parts := v.splitOn ";"
    parts.filterMap (fun p =>
      match p.splitOn "=" with
      | k::vs => some (k.trim, String.intercalate "=" vs |>.trim)
      | _ => none)

-- State helpers

def getUserById (st : AppState) (uid : Nat) : Option User := do
  match Simple.Map.find? st.usersById uid with
  | none => none
  | some ur => some { id := ur.id, username := ur.username }

-- Request body parsing

structure RegisterReq where
  username : String
  password : String
  deriving Repr

structure LoginReq where
  username : String
  password : String
  deriving Repr

structure PasswordReq where
  old_password : String
  new_password : String
  deriving Repr

structure CreateTodoReq where
  title : String
  description : Option String := none
  deriving Repr

structure UpdateTodoReq where
  title : Option String := none
  description : Option String := none
  completed : Option Bool := none
  deriving Repr

open Lean in
partial def decodeField (o : Json) (key : String) : Option Json :=
  match o with
  | Json.obj m =>
    let arr := m.toList
    match arr.find? (fun (p : String × Json) => p.fst = key) with
    | some p => some p.snd
    | none => none
  | _ => none

open Lean in
partial def parseJson (b : ByteArray) : Option Json :=
  match String.fromUTF8? b with
  | none => none
  | some s =>
    match Json.parse s with
    | Except.ok j => some j
    | Except.error _ => none

def getStrField (j : Lean.Json) (k : String) : Option String :=
  match decodeField j k with
  | some (Lean.Json.str s) => some s
  | _ => none

open Lean in
partial def parseRegister (b : ByteArray) : Option RegisterReq :=
  match parseJson b with
  | none => none
  | some j =>
    match (getStrField j "username", getStrField j "password") with
    | (some u, some p) => some { username := u, password := p }
    | _ => none

open Lean in
partial def parseLogin (b : ByteArray) : Option LoginReq :=
  match parseJson b with
  | none => none
  | some j =>
    match (getStrField j "username", getStrField j "password") with
    | (some u, some p) => some { username := u, password := p }
    | _ => none

open Lean in
partial def parsePassword (b : ByteArray) : Option PasswordReq :=
  match parseJson b with
  | none => none
  | some j =>
    match (getStrField j "old_password", getStrField j "new_password") with
    | (some o, some n) => some { old_password := o, new_password := n }
    | _ => none

open Lean in
partial def parseCreateTodo (b : ByteArray) : Option CreateTodoReq :=
  match parseJson b with
  | none => none
  | some j =>
    match getStrField j "title" with
    | some t =>
      let d := getStrField j "description"
      some { title := t, description := d }
    | none => none

open Lean in
partial def parseUpdateTodo (b : ByteArray) : Option UpdateTodoReq :=
  match parseJson b with
  | none => none
  | some j =>
    let t := getStrField j "title"
    let d := getStrField j "description"
    let c := match decodeField j "completed" with | some (Lean.Json.bool b) => some b | _ => none
    some { title := t, description := d, completed := c }

-- Authentication

def cookieLookup (cookies : List (String × String)) (k : String) : Option String :=
  match cookies.find? (fun (p : String × String) => p.fst.trim = k) with
  | some p => some p.snd
  | none => none

def authUser (stRef : SharedState) (hdrs : List (String × String)) : IO (Except Response Nat) := do
  let cookies := parseCookies hdrs
  match cookieLookup cookies "session_id" with
  | none =>
    let resp : Response := { status := 401, reason := "Unauthorized", headers := #[("Content-Type","application/json")], body := encodeJson (jsonError "Authentication required") }
    return .error resp
  | some tok =>
    let st ← stRef.get
    match Simple.Map.find? st.sessions tok with
    | none =>
      let resp : Response := { status := 401, reason := "Unauthorized", headers := #[("Content-Type","application/json")], body := encodeJson (jsonError "Authentication required") }
      return .error resp
    | some uid => return .ok uid

-- Core handler

def handle (stRef : SharedState) (req : Request) : IO Response := do
  let method := req.method
  let path := req.path
  if method == "POST" && path == "/register" then
    match parseRegister req.body with
    | none => return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Invalid username") }
    | some r =>
      if !isValidUsername r.username then
        return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Invalid username") }
      if r.password.length < 8 then
        return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Password too short") }
      let st ← stRef.get
      if Simple.Map.contains st.usersByName r.username then
        return { status := 409, reason := "Conflict", headers := #[], body := encodeJson (jsonError "Username already exists") }
      let uid := st.nextUserId
      let ur : UserRecord := { id := uid, username := r.username, password := r.password }
      let st' : AppState := { st with
        nextUserId := uid + 1
        usersByName := Simple.Map.insert st.usersByName r.username ur
        usersById := Simple.Map.insert st.usersById uid ur
      }
      stRef.set st'
      let userJson := Lean.Json.mkObj [("id", Lean.Json.num uid), ("username", Lean.Json.str r.username)]
      return { status := 201, reason := "Created", headers := #[], body := encodeJson userJson }
  else if method == "POST" && path == "/login" then
    match parseLogin req.body with
    | none => return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
    | some r =>
      let st ← stRef.get
      match Simple.Map.find? st.usersByName r.username with
      | some ur =>
        if ur.password == r.password then
          let tok ← newSessionToken
          let st' := { st with sessions := Simple.Map.insert st.sessions tok ur.id }
          stRef.set st'
          let userJson := Lean.Json.mkObj [("id", Lean.Json.num ur.id), ("username", Lean.Json.str ur.username)]
          let headers := #[("Set-Cookie", s!"session_id={tok}; Path=/; HttpOnly")]
          return { status := 200, reason := "OK", headers, body := encodeJson userJson }
        else
          return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
      | none => return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
  else if method == "POST" && path == "/logout" then
    match (← authUser stRef req.headers) with
    | .error resp => return resp
    | .ok _uid =>
      let cookies := parseCookies req.headers
      match cookieLookup cookies "session_id" with
      | none => return { status := 200, reason := "OK", headers := #[], body := encodeJson (Lean.Json.obj .empty) }
      | some tok =>
        let st ← stRef.get
        let st' := { st with sessions := Simple.Map.erase st.sessions tok }
        stRef.set st'
        return { status := 200, reason := "OK", headers := #[], body := encodeJson (Lean.Json.obj .empty) }
  else if method == "GET" && path == "/me" then
    match (← authUser stRef req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let st ← stRef.get
      match getUserById st uid with
      | some u =>
        let j := Lean.Json.mkObj [("id", Lean.Json.num u.id), ("username", Lean.Json.str u.username)]
        return { status := 200, reason := "OK", headers := #[], body := encodeJson j }
      | none =>
        return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Authentication required") }
  else if method == "PUT" && path == "/password" then
    match (← authUser stRef req.headers) with
    | .error resp => return resp
    | .ok uid =>
      match parsePassword req.body with
      | none => return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Password too short") }
      | some pr =>
        if pr.new_password.length < 8 then
          return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Password too short") }
        let st ← stRef.get
        match Simple.Map.find? st.usersById uid with
        | some ur =>
          if ur.password != pr.old_password then
            return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
          let ur' := { ur with password := pr.new_password }
          let st' := { st with
            usersById := Simple.Map.insert st.usersById uid ur'
            usersByName := Simple.Map.insert st.usersByName ur.username ur'
          }
          stRef.set st'
          return { status := 200, reason := "OK", headers := #[], body := encodeJson (Lean.Json.obj .empty) }
        | none => return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
  else if method == "GET" && path == "/todos" then
    match (← authUser stRef req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let st ← stRef.get
      let ids := Simple.Map.findD st.userTodoIds uid []
      let mut arr : Array Lean.Json := #[]
      for id in ids do
        match Simple.Map.find? st.todosById id with
        | some t => arr := arr.push (TodoItem.toJsonObj t)
        | none => pure ()
      let j := Lean.Json.arr arr
      return { status := 200, reason := "OK", headers := #[], body := encodeJson j }
  else if method == "POST" && path == "/todos" then
    match (← authUser stRef req.headers) with
    | .error resp => return resp
    | .ok uid =>
      match parseCreateTodo req.body with
      | none => return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Title is required") }
      | some r =>
        if r.title.trim == "" then
          return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Title is required") }
        let now ← nowIsoUtc
        let st ← stRef.get
        let tid := st.nextTodoId
        let t : TodoItem := { id := tid, ownerId := uid, title := r.title, description := r.description.getD "", completed := false, created_at := now, updated_at := now }
        let ids := Simple.Map.findD st.userTodoIds uid []
        let st' := { st with
          nextTodoId := tid + 1
          todosById := Simple.Map.insert st.todosById tid t
          userTodoIds := Simple.Map.insert st.userTodoIds uid (ids ++ [tid])
        }
        stRef.set st'
        return { status := 201, reason := "Created", headers := #[], body := encodeJson (TodoItem.toJsonObj t) }
  else if method == "GET" && path.startsWith "/todos/" then
    match (← authUser stRef req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let sid := path.drop "/todos/".length
      match sid.toNat? with
      | none => return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
      | some tid =>
        let st ← stRef.get
        match Simple.Map.find? st.todosById tid with
        | some t =>
          if t.ownerId != uid then
            return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
          else
            return { status := 200, reason := "OK", headers := #[], body := encodeJson (TodoItem.toJsonObj t) }
        | none => return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
  else if method == "PUT" && path.startsWith "/todos/" then
    match (← authUser stRef req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let sid := path.drop "/todos/".length
      match sid.toNat? with
      | none => return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
      | some tid =>
        match parseUpdateTodo req.body with
        | none => return { status := 200, reason := "OK", headers := #[], body := encodeJson (Lean.Json.obj .empty) }
        | some ureq =>
          if let some t := ureq.title then
            if t.trim == "" then
              return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Title is required") }
          let now ← nowIsoUtc
          let st ← stRef.get
          match Simple.Map.find? st.todosById tid with
          | none => return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
          | some t =>
            if t.ownerId != uid then
              return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
            let t' := { t with
              title := ureq.title.getD t.title
              description := ureq.description.getD t.description
              completed := ureq.completed.getD t.completed
              updated_at := now
            }
            let st' := { st with todosById := Simple.Map.insert st.todosById tid t' }
            stRef.set st'
            return { status := 200, reason := "OK", headers := #[], body := encodeJson (TodoItem.toJsonObj t') }
  else if method == "DELETE" && path.startsWith "/todos/" then
    match (← authUser stRef req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let sid := path.drop "/todos/".length
      match sid.toNat? with
      | none => return { status := 404, reason := "Not Found", headers := #[], body := ByteArray.empty }
      | some tid =>
        let st ← stRef.get
        match Simple.Map.find? st.todosById tid with
        | none => return { status := 404, reason := "Not Found", headers := #[], body := ByteArray.empty }
        | some t =>
          if t.ownerId != uid then
            return { status := 404, reason := "Not Found", headers := #[], body := ByteArray.empty }
          let st1 := { st with todosById := Simple.Map.erase st.todosById tid }
          let ids := Simple.Map.findD st1.userTodoIds uid []
          let ids' := ids.filter (· ≠ tid)
          let st2 := { st1 with userTodoIds := Simple.Map.insert st1.userTodoIds uid ids' }
          stRef.set st2
          return { status := 204, reason := "No Content", headers := #[("Content-Length","0")], body := ByteArray.empty }
  else
    return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Not found") }

-- HTTP over socat

partial def readHeaders (h : IO.FS.Handle) : IO (List String) := do
  let mut lines : List String := []
  while true do
    let ln ← h.getLine
    let s := ln.trimRight
    if s == "" then break
    lines := lines.append [s]
  pure lines

partial def parseRequest (firstLine : String) (hdrLines : List String) (body : ByteArray) : Request :=
  let parts := firstLine.splitOn " "
  let method := parts.getD 0 "GET"
  let path := parts.getD 1 "/"
  let version := parts.getD 2 "HTTP/1.1"
  let headers : List (String × String) := hdrLines.filterMap (fun l =>
    match l.splitOn ":" with
    | k::vs => some (k.trim, String.intercalate ":" vs |>.trim)
    | _ => none)
  { method, path, version, headers, body }

partial def readRequestFromSocket (hout : IO.FS.Handle) : IO (Option Request) := do
  let line ← hout.getLine
  if line.isEmpty then return none
  let first := line.trimRight
  let hdrs ← readHeaders hout
  let mut clen := 0
  for l in hdrs do
    if l.toLower.startsWith "content-length:" then
      match (l.drop 15).trim.toNat? with
      | some n => clen := n
      | none => pure ()
  let mut body : ByteArray := ByteArray.empty
  if clen > 0 then
    let bytes ← hout.read (USize.ofNat clen)
    body := bytes
  -- debug
  let bstr := match String.fromUTF8? body with | some s => s | none => "<invalid utf8>"
  IO.println s!"DBG first={first} clen={clen} body={bstr}"
  return some (parseRequest first hdrs body)

partial def writeResponse (hin : IO.FS.Handle) (r : Response) : IO Unit := do
  let mut headers := r.headers
  if r.status != 204 then
    if !(headers.any (·.fst.toLower == "content-type")) then
      headers := headers.push ("Content-Type", "application/json")
  if !(headers.any (·.fst.toLower == "content-length")) then
    headers := headers.push ("Content-Length", toString r.body.size)
  headers := headers.push ("Connection", "close")
  let start := s!"HTTP/1.1 {r.status} {r.reason}\r\n"
  let hdrStr := headers.foldl (fun acc (k,v) => acc ++ s!"{k}: {v}\r\n") start
  let out := hdrStr ++ "\r\n"
  hin.putStr out
  if r.body.size > 0 then
    hin.write r.body
  hin.flush

partial def serve (stRef : SharedState) (port : Nat) : IO Unit := do
  let portStr := toString port
  let cmd := s!"socat -d -d TCP-LISTEN:{portStr},fork,reuseaddr -"
  let child ← IO.Process.spawn { cmd := "bash", args := #["-lc", cmd], stdin := .piped, stdout := .piped, stderr := .inherit }
  let hout := child.stdout
  let hin := child.stdin
  while true do
    match (← readRequestFromSocket hout) with
    | none => pure ()
    | some req =>
      let resp ← handle stRef req
      writeResponse hin resp

-- Entry

def parsePort (args : List String) : Nat :=
  let rec go (as : List String) (p : Nat) : Nat :=
    match as with
    | [] => p
    | "--port"::v::rest => match v.toNat? with | some n => go rest n | none => go rest p
    | _::rest => go rest p
  go args 8080

def startServer (port : Nat) : IO Unit := do
  let stRef ← IO.mkRef (default : AppState)
  IO.println s!"Server listening on 0.0.0.0:{port}"
  serve stRef port

end Todo

open Todo in
def main (args : List String) : IO Unit := do
  let port := Todo.parsePort args
  Todo.startServer port
