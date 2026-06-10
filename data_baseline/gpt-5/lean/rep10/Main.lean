/-- C FFI bindings -/
@[extern "c_listen"]
opaque c_listen (host : @& String) (port : @& UInt16) : IO Int32
@[extern "c_accept"]
opaque c_accept (sockfd : @& Int32) : IO Int32
@[extern "c_read1"]
opaque c_read1 (fd : @& Int32) : IO Int32
@[extern "c_write"]
opaque c_write (fd : @& Int32) (buf : @& ByteArray) (n : @& USize) : IO Int32
@[extern "c_close"]
opaque c_close (fd : @& Int32) : IO Int32

open IO

abbrev UserId := Nat
abbrev TodoId := Nat

structure User where
  id : UserId
  username : String
  password : String

structure Todo where
  id : TodoId
  userId : UserId
  title : String
  description : String
  completed : Bool
  createdAt : String
  updatedAt : String

structure State where
  nextUserId : Nat := 1
  users : List User := []
  usersByUsername : List (String × UserId) := []
  sessions : List (String × UserId) := []
  nextTodoId : Nat := 1
  todos : List Todo := []

def List.findFirst? (xs : List α) (p : α → Bool) : Option α :=
  match xs with
  | [] => none
  | x::xt => if p x then some x else List.findFirst? xt p

namespace Util

private def hexDigitNat (v : Nat) : Char :=
  if v < 10 then Char.ofNat (v + 48) else Char.ofNat (v - 10 + 97)

def toHex (bs : ByteArray) : String :=
  Id.run do
    let mut s := ""
    for b in bs.data do
      let v := (b.toNat : Nat)
      let hi := v / 16
      let lo := v % 16
      s := s.push (hexDigitNat hi)
      s := s.push (hexDigitNat lo)
    s

def readRandomBytes (n : Nat) : IO ByteArray := do
  let h ← FS.Handle.mk "/dev/urandom" .read
  let bytes ← h.read (USize.ofNat n)
  pure bytes

def newToken : IO String := do
  let bs ← readRandomBytes 16
  pure (toHex bs)

-- constant time for portability
def nowIso8601 : IO String := pure "1970-01-01T00:00:00Z"

def jsonEscape (s : String) : String :=
  s.foldl (init := "") (fun acc c =>
    match c with
    | '"' => acc ++ "\\\""
    | '\\' => acc ++ "\\\\"
    | '\n' => acc ++ "\\n"
    | '\r' => acc ++ "\\r"
    | '\t' => acc ++ "\\t"
    | _ => acc.push c)

-- String helpers
def toLower (s : String) : String :=
  s.map fun c =>
    let n := c.toNat
    if 65 ≤ n ∧ n ≤ 90 then Char.ofNat (n + 32) else c

def trimLeft (s : String) : String :=
  let rec go (i : Nat) : Nat :=
    if h : i < s.length then
      let c := s.get ⟨i, h⟩
      if c == ' ' || c == '\n' || c == '\r' || c == '\t' then go (i+1) else i
    else i
  s.extract ⟨go 0, by decide⟩ ⟨s.length, by decide⟩

def trimRight (s : String) : String :=
  let rec go (i : Nat) : Nat :=
    if h : 0 < i then
      let j := i - 1
      have : j < s.length := by exact Nat.lt_of_lt_of_le (Nat.sub_lt (Nat.succ_le_of_lt (Nat.pos_of_ne_zero (by decide))) (by decide)) (by decide)
      let c := s.get ⟨j, by decide⟩
      if c == ' ' || c == '\n' || c == '\r' || c == '\t' then go j else i
    else i
  let n := go s.length
  s.extract ⟨0, by decide⟩ ⟨n, by decide⟩

def trim (s : String) : String := trimRight (trimLeft s)

-- very naive JSON field extraction for our limited inputs
def getStrField (body : String) (key : String) : Option String :=
  let k := "\"" ++ key ++ "\""
  let parts := body.splitOn k
  if parts.length < 2 then none else
    let tail := parts.get! 1
    let parts2 := tail.splitOn "\""
    if parts2.length < 2 then none else
      some (parts2.get! 1)

def getBoolField (body : String) (key : String) : Option Bool :=
  let k := "\"" ++ key ++ "\""
  let parts := body.splitOn k
  if parts.length < 2 then none else
    let tail := parts.get! 1
    let seg := trim tail
    if seg.startsWith ": true" || seg.startsWith ":true" then some true
    else if seg.startsWith ": false" || seg.startsWith ":false" then some false
    else none

-- small dict helpers
def lookupKV [DecidableEq α] (k : α) (xs : List (α × β)) : Option β :=
  match List.findFirst? xs (fun (a,_) => a == k) with
  | some (_,v) => some v
  | none => none

def insertKV [DecidableEq α] (k : α) (v : β) (xs : List (α × β)) : List (α × β) :=
  let xs' := xs.filter (fun (a,_) => a ≠ k)
  (k,v) :: xs'

def eraseKV [DecidableEq α] (k : α) (xs : List (α × β)) : List (α × β) :=
  xs.filter (fun (a,_) => a ≠ k)

-- validation
def validUsername (u : String) : Bool :=
  let n := u.length
  n ≥ 3 && n ≤ 50 && u.foldl (init := true) (fun ok c => ok && ((c.isAlphanum) || c == '_'))

def validPassword (p : String) : Bool := p.length ≥ 8

end Util

namespace Ser
open Util

def user (u : User) : String :=
  "{" ++ "\"id\": " ++ toString u.id ++ ", \"username\": \"" ++ jsonEscape u.username ++ "\"}"

def todo (t : Todo) : String :=
  let c := if t.completed then "true" else "false"
  "{" ++
  "\"id\": " ++ toString t.id ++ ", " ++
  "\"title\": \"" ++ jsonEscape t.title ++ "\", " ++
  "\"description\": \"" ++ jsonEscape t.description ++ "\", " ++
  "\"completed\": " ++ c ++ ", " ++
  "\"created_at\": \"" ++ t.createdAt ++ "\", " ++
  "\"updated_at\": \"" ++ t.updatedAt ++ "\"}"

def todos (ts : List Todo) : String :=
  let items := ts.map todo
  "[" ++ String.intercalate "," items ++ "]"

def okEmpty : String := "{}"

def err (msg : String) : String := "{" ++ "\"error\": \"" ++ jsonEscape msg ++ "\"}"

end Ser

structure HttpRequest where
  method : String
  path : String
  headers : List (String × String)
  body : String

structure HttpResponse where
  status : Nat
  reason : String
  headers : List (String × String)
  body : String

namespace Http
open Util

def parseHeaders (ls : List String) : List (String × String) :=
  ls.foldl (init := []) (fun acc l =>
    match l.splitOn ":" with
    | [] => acc
    | [k] => (toLower k.trim, "") :: acc
    | k::rest => (toLower k.trim, (String.intercalate ":" rest).trim) :: acc)

def lookupHeader (hdrs : List (String × String)) (name : String) : Option String :=
  lookupKV (toLower name) hdrs

def parseCookies (hdrs : List (String × String)) : List (String × String) :=
  match lookupHeader hdrs "cookie" with
  | none => []
  | some s =>
    s.splitOn ";" |>.foldl (init := []) (fun m kv =>
      match kv.splitOn "=" with
      | [k,v] => (k.trim, v.trim) :: m
      | _ => m)

def render (r : HttpResponse) : String :=
  let bodyBytes := r.body.toUTF8
  let statusLine := "HTTP/1.1 " ++ toString r.status ++ " " ++ r.reason ++ "\r\n"
  let hs := r.headers.foldl (init := "") (fun acc (k,v) => acc ++ k ++ ": " ++ v ++ "\r\n")
  let hs := hs ++ "Content-Length: " ++ toString bodyBytes.size ++ "\r\n"
  statusLine ++ hs ++ "\r\n" ++ r.body

partial def readLine (fd : Int32) (acc : String := "") : IO String := do
  let mut s := acc
  let mut lastCR := false
  while true do
    let n ← c_read1 fd
    if n < 0 then return s
    let c := Char.ofNat (Int.toNat n)
    s := s.push c
    if lastCR && c == '\n' then return s.dropRight 2
    lastCR := (c == '\r')

partial def readExact (fd : Int32) (n : Nat) : IO ByteArray := do
  let mut acc := ByteArray.empty
  for _ in [:n] do
    let b ← c_read1 fd
    if b < 0 then return acc
    acc := acc.push (UInt8.ofNat (Int.toNat b))
  return acc

partial def readRequest (fd : Int32) : IO (Option HttpRequest) := do
  let rl ← readLine fd
  if rl.isEmpty then return none
  let parts := rl.splitOn " "
  if parts.length < 3 then return none
  let method := parts.get! 0
  let path := parts.get! 1
  let rec loop (acc : List String) : IO (List String) := do
    let l ← readLine fd
    if l.isEmpty then return acc.reverse else loop (l :: acc)
  let hdrLines ← loop []
  let hdrs := parseHeaders hdrLines
  let contentLen := match lookupHeader hdrs "content-length" with
    | some v => (v.toNat?)?.getD 0
    | none => 0
  let body ← if contentLen > 0 then
    let ba ← readExact fd contentLen
    pure <| String.fromUTF8Unchecked ba
  else pure ""
  pure <| some { method, path, headers := hdrs, body }

def writeResponse (fd : Int32) (r : HttpResponse) : IO Unit := do
  let s := render r
  let ba := s.toUTF8
  let _ ← c_write fd ba ba.size.toUSize
  pure ()

end Http

structure App where
  state : IO.Ref State

namespace App
open Util Ser Http

def init : IO App := do
  let st : State := {}
  let r ← IO.mkRef st
  pure { state := r }

-- list utilities

def findUserById (xs : List User) (uid : UserId) : Option User :=
  List.findFirst? xs (fun u => u.id == uid)

def replaceUser (xs : List User) (u : User) : List User :=
  xs.map (fun x => if x.id == u.id then u else x)

def findTodoById (xs : List Todo) (tid : TodoId) : Option Todo :=
  List.findFirst? xs (fun t => t.id == tid)

def replaceTodo (xs : List Todo) (t : Todo) : List Todo :=
  xs.map (fun x => if x.id == t.id then t else x)

def eraseTodo (xs : List Todo) (tid : TodoId) : List Todo :=
  xs.filter (fun t => t.id ≠ tid)

private def insertSorted (t : Todo) (xs : List Todo) : List Todo :=
  match xs with
  | [] => [t]
  | x::rest => if t.id ≤ x.id then t::xs else x :: insertSorted t rest

def sortTodos (xs : List Todo) : List Todo :=
  xs.foldl insertSorted []

-- responses

def jsonError (code : Nat) (msg : String) : HttpResponse :=
  { status := code, reason := "Error", headers := [("Content-Type","application/json"),("Connection","close")], body := Ser.err msg }

def jsonOk (code : Nat) (body : String) (extra : List (String×String) := []) : HttpResponse :=
  { status := code, reason := "OK", headers := [("Content-Type","application/json"),("Connection","close")] ++ extra, body := body }

def noContent : HttpResponse := { status := 204, reason := "No Content", headers := [("Connection","close")], body := "" }

-- auth

def authUser (app : App) (req : HttpRequest) : IO (Option User × Option String) := do
  let cookies := Http.parseCookies req.headers
  let tok? := Util.lookupKV "session_id" cookies
  match tok? with
  | none => pure (none, none)
  | some tok =>
    let st ← app.state.get
    let uid? := Util.lookupKV tok st.sessions
    let u? := match uid? with | some uid => findUserById st.users uid | none => none
    pure (u?, some tok)

-- endpoints

def handleRegister (app : App) (req : HttpRequest) : IO HttpResponse := do
  let username? := Util.getStrField req.body "username"
  let password? := Util.getStrField req.body "password"
  let some username := username? | return jsonError 400 "Invalid username"
  let some password := password? | return jsonError 400 "Password too short"
  if !validUsername username then return jsonError 400 "Invalid username"
  if !validPassword password then return jsonError 400 "Password too short"
  let st ← app.state.get
  if (Util.lookupKV username st.usersByUsername).isSome then
    return { (jsonError 409 "Username already exists") with reason := "Conflict" }
  let uid := st.nextUserId
  let user : User := { id := uid, username := username, password := password }
  let st := { st with
    nextUserId := uid + 1,
    users := user :: st.users,
    usersByUsername := Util.insertKV username uid st.usersByUsername }
  app.state.set st
  return jsonOk 201 (Ser.user user)


def handleLogin (app : App) (req : HttpRequest) : IO HttpResponse := do
  let username? := Util.getStrField req.body "username"
  let password? := Util.getStrField req.body "password"
  let some username := username? | return jsonError 401 "Invalid credentials"
  let some password := password? | return jsonError 401 "Invalid credentials"
  let st ← app.state.get
  match Util.lookupKV username st.usersByUsername with
  | none => return jsonError 401 "Invalid credentials"
  | some uid =>
    match findUserById st.users uid with
    | none => return jsonError 401 "Invalid credentials"
    | some user =>
      if user.password ≠ password then
        return jsonError 401 "Invalid credentials"
      else
        let tok ← Util.newToken
        let st := { st with sessions := Util.insertKV tok uid st.sessions }
        app.state.set st
        return jsonOk 200 (Ser.user user) [("Set-Cookie", "session_id=" ++ tok ++ "; Path=/; HttpOnly")]


def requireAuth (app : App) (req : HttpRequest) : IO (Except HttpResponse (User × String)) := do
  let (u?, tok?) ← authUser app req
  match u?, tok? with
  | some u, some tok => pure (.ok (u, tok))
  | _, _ => pure (.error (jsonError 401 "Authentication required"))


def handleLogout (app : App) (req : HttpRequest) : IO HttpResponse := do
  let r ← requireAuth app req
  match r with
  | .error e => pure e
  | .ok (_, tok) =>
    let st ← app.state.get
    let st := { st with sessions := Util.eraseKV tok st.sessions }
    app.state.set st
    pure (jsonOk 200 Ser.okEmpty)


def handleMe (app : App) (req : HttpRequest) : IO HttpResponse := do
  let r ← requireAuth app req
  match r with
  | .error e => pure e
  | .ok (u, _) => pure (jsonOk 200 (Ser.user u))


def handlePassword (app : App) (req : HttpRequest) : IO HttpResponse := do
  let r ← requireAuth app req
  match r with
  | .error e => pure e
  | .ok (u, _) =>
    let oldp? := Util.getStrField req.body "old_password"
    let newp? := Util.getStrField req.body "new_password"
    let some oldp := oldp? | return jsonError 401 "Invalid credentials"
    let some newp := newp? | return jsonError 400 "Password too short"
    if oldp ≠ u.password then return jsonError 401 "Invalid credentials"
    if !validPassword newp then return jsonError 400 "Password too short"
    let st ← app.state.get
    let some ucur := findUserById st.users u.id | return jsonError 500 "Internal error"
    let u' := { ucur with password := newp }
    let st := { st with users := replaceUser st.users u' }
    app.state.set st
    return jsonOk 200 Ser.okEmpty


def handleGetTodos (app : App) (req : HttpRequest) : IO HttpResponse := do
  let r ← requireAuth app req
  match r with
  | .error e => pure e
  | .ok (u, _) =>
    let st ← app.state.get
    let ts := st.todos.filter (fun t => t.userId == u.id)
    pure (jsonOk 200 (Ser.todos (sortTodos ts)))


def handlePostTodos (app : App) (req : HttpRequest) : IO HttpResponse := do
  let r ← requireAuth app req
  match r with
  | .error e => pure e
  | .ok (u, _) =>
    let title? := Util.getStrField req.body "title"
    let desc := (Util.getStrField req.body "description").getD ""
    match title? with
    | none => pure (jsonError 400 "Title is required")
    | some t =>
      if t.trim.isEmpty then return jsonError 400 "Title is required"
      let now ← Util.nowIso8601
      let st ← app.state.get
      let tid := st.nextTodoId
      let todo : Todo := { id := tid, userId := u.id, title := t, description := desc, completed := false, createdAt := now, updatedAt := now }
      let st := { st with nextTodoId := tid + 1, todos := todo :: st.todos }
      app.state.set st
      pure (jsonOk 201 (Ser.todo todo))

private def parseTodoId (path : String) : Option Nat :=
  let parts := path.splitOn "/"
  match parts with
  | _ :: "todos" :: id :: [] => id.toNat?
  | _ => none

private def getTodoForUser (st : State) (uid : UserId) (tid : Nat) : Option Todo :=
  match findTodoById st.todos tid with
  | some t => if t.userId == uid then some t else none
  | none => none


def handleGetTodo (app : App) (req : HttpRequest) (tid : Nat) : IO HttpResponse := do
  let r ← requireAuth app req
  match r with
  | .error e => pure e
  | .ok (u, _) =>
    let st ← app.state.get
    let t? := getTodoForUser st u.id tid
    match t? with
    | none => pure (jsonError 404 "Todo not found")
    | some t => pure (jsonOk 200 (Ser.todo t))


def handlePutTodo (app : App) (req : HttpRequest) (tid : Nat) : IO HttpResponse := do
  let r ← requireAuth app req
  match r with
  | .error e => pure e
  | .ok (u, _) =>
    let st ← app.state.get
    let mt := getTodoForUser st u.id tid
    match mt with
    | none => pure (jsonError 404 "Todo not found")
    | some t =>
      match Util.getStrField req.body "title" with
      | some s => if s.trim.isEmpty then pure (jsonError 400 "Title is required") else pure ()
      | none => pure ()
      let title := (Util.getStrField req.body "title").getD t.title
      let desc := (Util.getStrField req.body "description").getD t.description
      let completed := (Util.getBoolField req.body "completed").getD t.completed
      let now ← Util.nowIso8601
      let t' := { t with title := title, description := desc, completed := completed, updatedAt := now }
      let st := { st with todos := replaceTodo st.todos t' }
      app.state.set st
      pure (jsonOk 200 (Ser.todo t'))


def handleDeleteTodo (app : App) (req : HttpRequest) (tid : Nat) : IO HttpResponse := do
  let r ← requireAuth app req
  match r with
  | .error e => pure e
  | .ok (u, _) =>
    let st ← app.state.get
    let mt := getTodoForUser st u.id tid
    match mt with
    | none => pure (jsonError 404 "Todo not found")
    | some _ =>
      let st := { st with todos := eraseTodo st.todos tid }
      app.state.set st
      pure noContent


def route (app : App) (req : HttpRequest) : IO HttpResponse := do
  match req.method, req.path with
  | "POST", "/register" => handleRegister app req
  | "POST", "/login" => handleLogin app req
  | "POST", "/logout" => handleLogout app req
  | "GET", "/me" => handleMe app req
  | "PUT", "/password" => handlePassword app req
  | "GET", "/todos" => handleGetTodos app req
  | "POST", "/todos" => handlePostTodos app req
  | "GET", _ => match parseTodoId req.path with | some tid => handleGetTodo app req tid | none => pure (jsonError 404 "Not Found")
  | "PUT", _ => match parseTodoId req.path with | some tid => handlePutTodo app req tid | none => pure (jsonError 404 "Not Found")
  | "DELETE", _ => match parseTodoId req.path with | some tid => handleDeleteTodo app req tid | none => pure (jsonError 404 "Not Found")
  | _, _ => pure (jsonError 404 "Not Found")

end App

open App Http

partial def clientLoop (app : App) (fd : Int32) : IO Unit := do
  try
    match ← Http.readRequest fd with
    | none => pure ()
    | some req =>
      let resp ← app.route req
      let resp := if resp.status == 204 then resp else
        let hasCT := resp.headers.any (fun (k,_) => Util.toLower k == "content-type")
        if hasCT then resp else { resp with headers := ("Content-Type", "application/json") :: resp.headers }
      Http.writeResponse fd resp
  finally
    let _ ← c_close fd
    pure ()

partial def acceptLoop (app : App) (lsock : Int32) : IO Unit := do
  let cfd ← c_accept lsock
  if cfd ≥ 0 then
    -- handle sequentially to avoid needing threads
    clientLoop app cfd
  acceptLoop app lsock

def runServer (portStr : String) : IO Unit := do
  let app ← App.init
  let port := (portStr.toNat?).getD 8080
  let lsock ← c_listen "0.0.0.0" (UInt16.ofNat port)
  if lsock < 0 then throw <| IO.userError "Failed to listen"
  acceptLoop app lsock

def main (args : List String) : IO Unit := do
  let mut port := "8080"
  let rec loop (xs : List String) : IO Unit :=
    match xs with
    | [] => pure ()
    | "--port" :: p :: rest => port := p; loop rest
    | _ :: rest => loop rest
  loop args
  println! ("Starting server on 0.0.0.0:" ++ port)
  runServer port
