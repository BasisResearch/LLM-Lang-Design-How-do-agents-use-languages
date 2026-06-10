import Std
import Std.Async.TCP
import Std.Net.Addr
import Lean.Data.Json
open Std
open Std.Async
open Std.Net
open Lean

structure Request where
  method : String
  path : String
  headers : List (String × String)
  body : ByteArray
  deriving Inhabited

structure Response where
  status : Nat
  statusText : String
  headers : List (String × String)
  body : ByteArray
  deriving Inhabited

-- In-memory models
structure User where
  id : Nat
  username : String
  password : String
  deriving Inhabited, BEq

structure Todo where
  id : Nat
  userId : Nat
  title : String
  description : String
  completed : Bool
  createdAt : String
  updatedAt : String
  deriving Inhabited, BEq

structure Session where
  token : String
  userId : Nat
  deriving Inhabited, BEq

structure AppState where
  nextUserId : Nat := 1
  nextTodoId : Nat := 1
  users : Std.HashMap String User := {}
  usersById : Std.HashMap Nat User := {}
  sessions : Std.HashMap String Session := {}
  todos : Std.HashMap Nat Todo := {}
  deriving Inhabited

abbrev App := IO.Ref AppState

-- Utilities
private def trimASCII (s : String) : String :=
  let cs := s.toList
  let cs1 := cs.dropWhile (fun c => c = ' ' || c = '\n' || c = '\r' || c = '\t')
  let cs2 := cs1.reverse.dropWhile (fun c => c = ' ' || c = '\n' || c = '\r' || c = '\t') |>.reverse
  String.ofList cs2

private def pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else toString n

private def isLeap (y : Nat) : Bool :=
  (y % 400 = 0) || ((y % 4 = 0) && (y % 100 ≠ 0))

private def monthDays (y : Nat) : Array Nat :=
  #[(31),(if isLeap y then 29 else 28),(31),(30),(31),(30),(31),(31),(30),(31),(30),(31)]

def nowIso8601 : IO String := do
  let ms ← IO.monoMsNow
  let secs : Nat := ms / 1000
  let days := secs / 86400
  let rem := secs % 86400
  let hour := rem / 3600
  let rem2 := rem % 3600
  let minute := rem2 / 60
  let second := rem2 % 60
  let mut y : Nat := 1970
  let mut d : Nat := days
  while d ≥ (if isLeap y then 366 else 365) do
    d := d - (if isLeap y then 366 else 365)
    y := y + 1
  let mds := monthDays y
  let mut mIdx : Nat := 0
  let mut dd : Nat := d
  while mIdx < mds.size && dd ≥ mds[mIdx]! do
    dd := dd - mds[mIdx]!
    mIdx := mIdx + 1
  let month := mIdx + 1
  let day := dd + 1
  let yStr := toString y
  let hh := pad2 hour
  let mm := pad2 minute
  let ss := pad2 second
  pure s!"{yStr}-{pad2 month}-{pad2 day}T{hh}:{mm}:{ss}Z"

-- JSON helpers

def userToJson (u : User) : Json :=
  Json.mkObj [
    ("id", toJson u.id),
    ("username", toJson u.username)
  ]

def todoToJson (t : Todo) : Json :=
  Json.mkObj [
    ("id", toJson t.id),
    ("title", toJson t.title),
    ("description", toJson t.description),
    ("completed", toJson t.completed),
    ("created_at", toJson t.createdAt),
    ("updated_at", toJson t.updatedAt)
  ]

def todosToJson (ts : List Todo) : Json :=
  Json.arr <| (ts.map (fun t => todoToJson t)).toArray

def errorJson (msg : String) : Json := Json.mkObj [("error", toJson msg)]

private def jsonToBody (j : Json) : ByteArray := (toString j).toUTF8

-- Headers
private def lower (s : String) : String := String.map Char.toLower s

def headerLookup (hs : List (String × String)) (name : String) : Option String :=
  let n := lower name
  hs.findSome? (fun (k,v) => if lower k = n then some v else none)

-- Cookie parsing

def parseCookies (headers : List (String × String)) : Std.HashMap String String :=
  match headerLookup headers "Cookie" with
  | none => {}
  | some v =>
    v.splitOn ";" |>.foldl (init := {}) fun acc part =>
      let kv := part.splitOn "="
      if kv.length = 2 then acc.insert (trimASCII kv[0]!) (trimASCII kv[1]!) else acc

-- Validation

def validUsername (u : String) : Bool :=
  let n := u.length
  if n < 3 || n > 50 then false else
  u.toList.all (fun c => c.isAlphanum || c = '_')

-- Response builders

def jsonResp (code : Nat) (j : Json) (extraHeaders := ([] : List (String × String))) : Response :=
  { status := code
  , statusText := match code with
      | 200 => "OK" | 201 => "Created" | 204 => "No Content" | 400 => "Bad Request" | 401 => "Unauthorized" | 403 => "Forbidden" | 404 => "Not Found" | 409 => "Conflict" | _ => "OK"
  , headers := ("Content-Type", "application/json") :: extraHeaders
  , body := jsonToBody j
  }

def noBodyResp (code : Nat) (extraHeaders := ([] : List (String × String))) : Response :=
  { status := code, statusText := (if code = 204 then "No Content" else "OK"), headers := extraHeaders, body := ByteArray.empty }

-- JSON access helpers
private def getStrField (j : Json) (k : String) : Except String String := do
  let v ← j.getObjVal? k
  fromJson? v

private def getOptStr (j : Json) (k : String) : Option String :=
  match (j.getObjVal? k).toOption with
  | none => none
  | some v => (fromJson? v).toOption

private def getOptBool (j : Json) (k : String) : Option Bool :=
  match (j.getObjVal? k).toOption with
  | none => none
  | some v => (fromJson? v).toOption

-- Auth helper

def withAuth (app : App) (req : Request) (k : User → IO Response) : IO Response := do
  let cookies := parseCookies req.headers
  match cookies["session_id"]? with
  | none => pure <| jsonResp 401 (errorJson "Authentication required")
  | some tok =>
    let st ← app.get
    match st.sessions[ tok ]? with
    | none => pure <| jsonResp 401 (errorJson "Authentication required")
    | some s =>
      match st.usersById[ s.userId ]? with
      | none => pure <| jsonResp 401 (errorJson "Authentication required")
      | some u => k u

-- Handlers

def handleRegister (app : App) (req : Request) : IO Response := do
  let bodyStr := String.fromUTF8! req.body
  match Json.parse bodyStr with
  | .error _ => return jsonResp 400 (errorJson "Invalid username")
  | .ok j =>
    match getStrField j "username", getStrField j "password" with
    | .ok username, .ok password =>
      if !validUsername username then return jsonResp 400 (errorJson "Invalid username")
      if password.length < 8 then return jsonResp 400 (errorJson "Password too short")
      let st ← app.get
      if st.users.contains username then
        return jsonResp 409 (errorJson "Username already exists")
      else
        let id := st.nextUserId
        let u : User := { id, username, password }
        let st' := { st with nextUserId := id + 1, users := st.users.insert username u, usersById := st.usersById.insert id u }
        app.set st'
        return jsonResp 201 (userToJson u)
    | _, _ => return jsonResp 400 (errorJson "Invalid username")

def handleLogin (app : App) (req : Request) : IO Response := do
  let bodyStr := String.fromUTF8! req.body
  match Json.parse bodyStr with
  | .error _ => return jsonResp 401 (errorJson "Invalid credentials")
  | .ok j =>
    match getStrField j "username", getStrField j "password" with
    | .ok username, .ok password =>
      let st ← app.get
      match st.users[username]? with
      | some u =>
        if u.password = password then
          let b ← IO.getRandomBytes (USize.ofNat 16)
          let token := (b.data.toList.map (fun bt =>
            let v := bt.toNat
            let hi := v / 16
            let lo := v % 16
            let hexNib (n : Nat) : Char :=
              match n with
              | 0 => '0' | 1 => '1' | 2 => '2' | 3 => '3' | 4 => '4' | 5 => '5' | 6 => '6' | 7 => '7'
              | 8 => '8' | 9 => '9' | 10 => 'a' | 11 => 'b' | 12 => 'c' | 13 => 'd' | 14 => 'e' | _ => 'f'
            String.ofList [hexNib hi, hexNib lo]
          )).foldl (·++·) ""
          let sess : Session := { token := token, userId := u.id }
          let st' := { st with sessions := st.sessions.insert token sess }
          app.set st'
          return jsonResp 200 (userToJson u) (("Set-Cookie", s!"session_id={token}; Path=/; HttpOnly") :: [])
        else return jsonResp 401 (errorJson "Invalid credentials")
      | none => return jsonResp 401 (errorJson "Invalid credentials")
    | _, _ => return jsonResp 401 (errorJson "Invalid credentials")

def handleLogout (app : App) (req : Request) : IO Response := do
  withAuth app req fun _ => do
    let cookies := parseCookies req.headers
    match cookies["session_id"]? with
    | none => return jsonResp 200 (Json.mkObj [])
    | some tok =>
      let st ← app.get
      let st' := { st with sessions := st.sessions.erase tok }
      app.set st'
      return jsonResp 200 (Json.mkObj [])

def handleMe (app : App) (req : Request) : IO Response :=
  withAuth app req fun u => pure <| jsonResp 200 (userToJson u)

def handlePassword (app : App) (req : Request) : IO Response := do
  withAuth app req fun u => do
    let bodyStr := String.fromUTF8! req.body
    match Json.parse bodyStr with
    | .error _ => return jsonResp 401 (errorJson "Invalid credentials")
    | .ok j =>
      match getStrField j "old_password", getStrField j "new_password" with
      | .ok oldp, .ok newp =>
        if newp.length < 8 then return jsonResp 400 (errorJson "Password too short")
        if oldp ≠ u.password then return jsonResp 401 (errorJson "Invalid credentials")
        let st ← app.get
        let u' := { u with password := newp }
        let st' := { st with users := st.users.insert u.username u', usersById := st.usersById.insert u.id u' }
        app.set st'
        return jsonResp 200 (Json.mkObj [])
      | _, _ => return jsonResp 401 (errorJson "Invalid credentials")

-- Sorting
private def insertBy (cmp : α → α → Bool) (x : α) : List α → List α
| [] => [x]
| y :: ys => if cmp x y then x :: y :: ys else y :: insertBy cmp x ys

private def sortBy (cmp : α → α → Bool) : List α → List α
| [] => []
| x :: xs => insertBy cmp x (sortBy cmp xs)

-- Todo helpers

def userTodos (st : AppState) (uid : Nat) : List Todo :=
  let ts := st.todos.toList.map (·.snd)
  let ts := ts.filter (fun t => t.userId = uid)
  sortBy (fun a b => a.id ≤ b.id) ts

-- Path helper

def parseIdFromPath (path : String) : Option Nat :=
  match path.splitOn "/" with
  | ["", "todos", idStr] => idStr.toNat?
  | _ => none

-- Todo handlers

def handleTodosGet (app : App) (req : Request) : IO Response := do
  withAuth app req fun u => do
    let st ← app.get
    let ts := userTodos st u.id
    return jsonResp 200 (todosToJson ts)

def handleTodosPost (app : App) (req : Request) : IO Response := do
  withAuth app req fun u => do
    let bodyStr := String.fromUTF8! req.body
    match Json.parse bodyStr with
    | .error _ => return jsonResp 400 (errorJson "Title is required")
    | .ok j =>
      match getStrField j "title" with
      | .ok t =>
        if trimASCII t = "" then return jsonResp 400 (errorJson "Title is required") else
        let desc := (getOptStr j "description").getD ""
        let now ← nowIso8601
        let st ← app.get
        let id := st.nextTodoId
        let todo : Todo := { id, userId := u.id, title := t, description := desc, completed := false, createdAt := now, updatedAt := now }
        let st' := { st with nextTodoId := id + 1, todos := st.todos.insert id todo }
        app.set st'
        return jsonResp 201 (todoToJson todo)
      | _ => return jsonResp 400 (errorJson "Title is required")

def handleTodoGet (app : App) (req : Request) : IO Response := do
  withAuth app req fun u => do
    match parseIdFromPath req.path with
    | none => return jsonResp 404 (errorJson "Todo not found")
    | some id =>
      let st ← app.get
      match st.todos[id]? with
      | some t => if t.userId = u.id then return jsonResp 200 (todoToJson t) else return jsonResp 404 (errorJson "Todo not found")
      | none => return jsonResp 404 (errorJson "Todo not found")

def handleTodoPut (app : App) (req : Request) : IO Response := do
  withAuth app req fun u => do
    match parseIdFromPath req.path with
    | none => return jsonResp 404 (errorJson "Todo not found")
    | some id =>
      let st ← app.get
      match st.todos[id]? with
      | none => return jsonResp 404 (errorJson "Todo not found")
      | some t =>
        if t.userId ≠ u.id then return jsonResp 404 (errorJson "Todo not found")
        let bodyStr := String.fromUTF8! req.body
        match Json.parse bodyStr with
        | .error _ => return jsonResp 200 (todoToJson t)
        | .ok j =>
          match getOptStr j "title" with
          | some tt => if trimASCII tt = "" then return jsonResp 400 (errorJson "Title is required") else pure ()
          | none => pure ()
          let t1 := match getOptStr j "title" with | some v => { t with title := v } | none => t
          let t2 := match getOptStr j "description" with | some v => { t1 with description := v } | none => t1
          let t3 := match getOptBool j "completed" with | some v => { t2 with completed := v } | none => t2
          let now ← nowIso8601
          let t4 := { t3 with updatedAt := now }
          let st' := { st with todos := st.todos.insert id t4 }
          app.set st'
          return jsonResp 200 (todoToJson t4)


def handleTodoDelete (app : App) (req : Request) : IO Response := do
  withAuth app req fun u => do
    match parseIdFromPath req.path with
    | none => return jsonResp 404 (errorJson "Todo not found")
    | some id =>
      let st ← app.get
      match st.todos[id]? with
      | some t =>
        if t.userId ≠ u.id then return jsonResp 404 (errorJson "Todo not found") else
        let st' := { st with todos := st.todos.erase id }
        app.set st'
        return noBodyResp 204
      | none => return jsonResp 404 (errorJson "Todo not found")

-- Router

def route (app : App) (req : Request) : IO Response := do
  match (req.method, req.path) with
  | ("POST", "/register") => handleRegister app req
  | ("POST", "/login") => handleLogin app req
  | ("POST", "/logout") => handleLogout app req
  | ("GET", "/me") => handleMe app req
  | ("PUT", "/password") => handlePassword app req
  | ("GET", "/todos") => handleTodosGet app req
  | ("POST", "/todos") => handleTodosPost app req
  | (m, p) =>
    if m = "GET" && p.startsWith "/todos/" then handleTodoGet app req
    else if m = "PUT" && p.startsWith "/todos/" then handleTodoPut app req
    else if m = "DELETE" && p.startsWith "/todos/" then handleTodoDelete app req
    else pure <| jsonResp 404 (errorJson "Not Found")

-- HTTP parsing/writing on TCP

private def findCRLFCRLF (ba : ByteArray) : Option Nat :=
  let n := ba.size
  let rec loop (i : Nat) : Option Nat :=
    if i + 3 ≥ n then none
    else
      let a := ba.get! i
      let b := ba.get! (i+1)
      let c := ba.get! (i+2)
      let d := ba.get! (i+3)
      if a = 13 && b = 10 && c = 13 && d = 10 then some (i+4) else loop (i+1)
  loop 0

private def byteArrayToString (ba : ByteArray) : String := String.fromUTF8! ba

private def parseHeaders (s : String) : List (String × String) :=
  s.splitOn "\r\n" |>.filter (· ≠ "") |>.map (fun line =>
    match line.splitOn ":" with
    | k :: v => (k, String.intercalate ":" v |> trimASCII)
    | _ => (line, ""))

private def parseRequestFrom (buf : ByteArray) : Option (Request × ByteArray) :=
  match findCRLFCRLF buf with
  | none => none
  | some headerEnd =>
    let headerBytes := buf.extract 0 headerEnd
    let headerStr := byteArrayToString headerBytes
    let lines := headerStr.splitOn "\r\n" |>.filter (· ≠ "")
    if lines.isEmpty then none else
    let reqLine := lines.head!
    let parts := reqLine.splitOn " "
    if parts.length < 2 then none else
    let method := parts[0]!
    let path := parts[1]!
    let headers := parseHeaders (String.intercalate "\r\n" (lines.drop 1))
    let cl := headerLookup headers "Content-Length" |>.bind (·.toNat?) |>.getD 0
    let remain := buf.extract headerEnd buf.size
    if remain.size ≥ cl then
      let body := remain.extract 0 cl
      let leftover := remain.extract cl remain.size
      some ({ method, path, headers, body } , leftover)
    else
      none

private def buildResponseBytes (resp : Response) : ByteArray :=
  let status := s!"HTTP/1.1 {resp.status} {resp.statusText}\r\n"
  let baseHeaders := resp.headers
  let headerStr := String.intercalate "" (baseHeaders.map (fun (k,v) => s!"{k}: {v}\r\n"))
  let head := status ++ headerStr ++ s!"Content-Length: {resp.body.size}\r\n\r\n"
  let headBytes := head.toUTF8
  headBytes ++ resp.body

-- Connection handler

partial def readUntilRequest (client : TCP.Socket.Client) (buf : ByteArray) : IO (Option (Request × ByteArray)) := do
  match parseRequestFrom buf with
  | some rp => return some rp
  | none =>
    let chunk? ← (TCP.Socket.Client.recv? client 65536).block
    match chunk? with
    | none => return none
    | some chunk => readUntilRequest client (buf ++ chunk)

def handleClient (app : App) (client : TCP.Socket.Client) : IO Unit := do
  match ← readUntilRequest client ByteArray.empty with
  | none => pure ()
  | some (req, _leftover) =>
    let resp ← route app req
    let bytes := buildResponseBytes resp
    let _ ← (TCP.Socket.Client.send client bytes).block
    let _ ← (TCP.Socket.Client.shutdown client).block
    pure ()

-- TCP server

def runServer (port : Nat) : IO Unit := do
  let app ← IO.mkRef ({} : AppState)
  let server ← TCP.Socket.Server.mk
  let addr := SocketAddressV4.mk (.ofParts 0 0 0 0) (UInt16.ofNat port)
  TCP.Socket.Server.bind server addr
  TCP.Socket.Server.listen server 128
  IO.println s!"Listening on 0.0.0.0:{port}"
  while true do
    let client ← (TCP.Socket.Server.accept server).block
    let appRef := app
    discard <| IO.asTask (handleClient appRef client) Task.Priority.dedicated

-- CLI
private def parseArgs (args : List String) : Nat :=
  match args with
  | "--port" :: p :: _ => p.toNat!
  | _ => 8080

def main (argv : List String) : IO Unit := do
  let port := parseArgs argv
  runServer port
