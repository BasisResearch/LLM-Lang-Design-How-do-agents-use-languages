import Lean
import Std

open IO
open Std

namespace Todo

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

-- Public JSON view for TodoItem (without ownerId)
namespace TodoItem
  def toJsonObj (t : TodoItem) : Lean.Json :=
    Lean.Json.mkObj [
      ("id", Lean.Json.num (t.id))
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
  usersByName : HashMap String UserRecord := {}
  usersById : HashMap Nat UserRecord := {}
  sessions : HashMap String Nat := {}
  todosById : HashMap Nat TodoItem := {}
  userTodoIds : HashMap Nat (Array Nat) := {}
  deriving Inhabited

abbrev SharedState := MVar AppState

-- Simple validation helpers

def isValidUsername (u : String) : Bool :=
  let n := u.length
  let goodLen := n >= 3 && n <= 50
  let goodChars := u.data.all fun c =>
    (c.isAlphanum) || c == '_'
  goodLen && goodChars

-- Get current time in ISO8601 UTC with seconds using external `date` utility
def nowIsoUtc : IO String := do
  let out ← IO.Process.output { cmd := "date", args := #['-u', "+%Y-%m-%dT%H:%M:%SZ"] }
  pure out.stdout.trim

-- Create a random session token by reading kernel uuid and stripping dashes
def newSessionToken : IO String := do
  try
    let s ← FS.readFile "/proc/sys/kernel/random/uuid"
    pure <| (s.trim.replace "-" "")
  catch _ =>
    -- Fallback: timestamp-based token (not cryptographically secure)
    let t ← nowIsoUtc
    pure ("tok_" ++ t)

-- HTTP primitives

structure Request where
  method : String
  path : String
  version : String
  headers : HashMap String String
  body : ByteArray
  deriving Repr

structure Response where
  status : Nat
  reason : String
  headers : Array (String × String)
  body : ByteArray

namespace Http

def crlfcrlf : List UInt8 := [13,10,13,10]

def findSubseq (buf : ByteArray) (pat : List UInt8) : Option Nat :=
  let plen := pat.length
  if plen == 0 then return some 0
  let arr := buf.toArray
  let n := arr.size
  let rec loop (i : Nat) : Option Nat :=
    if i + plen > n then none
    else
      let ok := List.allIdx pat (fun j b => arr[i+j]! = b)
      if ok then some i else loop (i+1)
  loop 0
where
  -- check all items at indices j
  List.allIdx (xs : List α) (p : Nat → α → Bool) : Bool :=
    let rec go : Nat → List α → Bool
    | _, [] => true
    | j, a::as => if p j a then go (j+1) as else false
    go 0 xs

def lower (s : String) : String := s.map fun c => c.toLower

def parseHeaders (s : String) : HashMap String String :=
  let lines := s.splitOn "\r\n"
  let kvs := lines.filterMap (fun l =>
    match l.splitOn ":" with
    | k::vs => some (lower k.trim, String.intercalate ":" vs |>.trim)
    | _ => none)
  HashMap.ofList kvs

def readRequest (sock : Socket) : IO (Option Request) := do
  let mut buf : ByteArray := ByteArray.empty
  let mut hdrPos : Option Nat := none
  -- Read until we find CRLFCRLF or connection closes
  while hdrPos.isNone do
    let chunk ← sock.recv 4096
    if chunk.size == 0 then
      if buf.size == 0 then return none else break
    buf := buf ++ chunk
    hdrPos := findSubseq buf crlfcrlf
  let some pos := hdrPos | return none
  let hdrBytes := buf.extract 0 (pos + 4)
  let bodyLeft := buf.extract (pos + 4) buf.size
  let hdrStr := String.fromUTF8Unchecked hdrBytes
  let lines := hdrStr.splitOn "\r\n"
  let reqLine := lines.headD ""
  let parts := reqLine.splitOn " "
  if parts.length < 3 then return none
  let method := parts.get! 0
  let path := parts.get! 1
  let version := parts.get! 2
  -- Re-join header lines excluding the first request line and final empty line
  let headerBlob := String.intercalate "\r\n" (lines.drop 1 |>.filter (fun s => s != ""))
  let headers := parseHeaders headerBlob
  -- Read body based on Content-Length
  let clen := match headers.find? (lower "Content-Length") with
              | some v => v.toNat?
              | none => some 0
  let need := match clen with | some n => n | none => 0
  let mut body := bodyLeft
  if need > body.size then
    let toRead := need - body.size
    let mut rem := toRead
    while rem > 0 do
      let chunk ← sock.recv (min rem 4096)
      if chunk.size == 0 then break
      body := body ++ chunk
      rem := rem - chunk.size
  pure <| some { method, path, version, headers, body }

def toByteArray (s : String) : ByteArray := s.toUTF8

def renderResponse (r : Response) : ByteArray :=
  let statusLine := s!"HTTP/1.1 {r.status} {r.reason}\r\n"
  let mut hdrs := r.headers
  -- Ensure Connection: close
  if !(hdrs.any (·.fst.toLower == "connection")) then
    hdrs := hdrs.push ("Connection", "close")
  -- Ensure Content-Length and default Content-Type if body exists
  if r.body.size > 0 then
    if !(hdrs.any (·.fst.toLower == "content-length")) then
      hdrs := hdrs.push ("Content-Length", toString r.body.size)
    if !(hdrs.any (·.fst.toLower == "content-type")) then
      hdrs := hdrs.push ("Content-Type", "application/json")
  else
    -- Explicitly set Content-Length 0 for clarity when no body
    if !(hdrs.any (·.fst.toLower == "content-length")) then
      hdrs := hdrs.push ("Content-Length", "0")
  let headerStr := hdrs.foldl (fun acc (k,v) => acc ++ s!"{k}: {v}\r\n") statusLine
  let full := headerStr ++ "\r\n"
  let mut out := toByteArray full
  if r.body.size > 0 then out := out ++ r.body
  out

end Http

-- JSON helpers

def jsonError (msg : String) : Lean.Json := Lean.Json.mkObj [("error", Lean.Json.str msg)]

def encodeJson (j : Lean.Json) : ByteArray := j.compress.print! |>.toUTF8

def strBody (s : String) : ByteArray := s.toUTF8

-- Cookie parsing

def parseCookies (hdrs : HashMap String String) : HashMap String String :=
  match hdrs.find? "cookie" with
  | none => {}
  | some v =>
    let parts := v.splitOn ";"
    let kvs := parts.filterMap (fun p =>
      match p.splitOn "=" with
      | k::vs => some (k.trim, String.intercalate "=" vs |>.trim)
      | _ => none)
    HashMap.ofList kvs

-- State accessors

def getUserById (st : AppState) (uid : Nat) : Option User := do
  let ur ← st.usersById.find? uid
  some { id := ur.id, username := ur.username }

def todoPublicJson (t : TodoItem) : Lean.Json :=
  TodoItem.toJsonObj t

-- Request body decoders (simple, manual)

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
  | .obj m => m.find? key
  | _ => none

open Lean in
partial def parseRegister (b : ByteArray) : Option RegisterReq :=
  match Json.parse (String.fromUTF8Unchecked b) with
  | Except.error _ => none
  | Except.ok j =>
    match (decodeField j "username", decodeField j "password") with
    | (some (.str u), some (.str p)) => some { username := u, password := p }
    | _ => none

open Lean in
partial def parseLogin (b : ByteArray) : Option LoginReq :=
  match Json.parse (String.fromUTF8Unchecked b) with
  | Except.error _ => none
  | Except.ok j =>
    match (decodeField j "username", decodeField j "password") with
    | (some (.str u), some (.str p)) => some { username := u, password := p }
    | _ => none

open Lean in
partial def parsePassword (b : ByteArray) : Option PasswordReq :=
  match Json.parse (String.fromUTF8Unchecked b) with
  | Except.error _ => none
  | Except.ok j =>
    match (decodeField j "old_password", decodeField j "new_password") with
    | (some (.str o), some (.str n)) => some { old_password := o, new_password := n }
    | _ => none

open Lean in
partial def parseCreateTodo (b : ByteArray) : Option CreateTodoReq :=
  match Json.parse (String.fromUTF8Unchecked b) with
  | Except.error _ => none
  | Except.ok j =>
    let title? := decodeField j "title"
    let desc? := decodeField j "description"
    match title? with
    | some (.str t) =>
      let d := match desc? with | some (.str s) => some s | _ => none
      some { title := t, description := d }
    | _ => none

open Lean in
partial def parseUpdateTodo (b : ByteArray) : Option UpdateTodoReq :=
  match Json.parse (String.fromUTF8Unchecked b) with
  | Except.error _ => none
  | Except.ok j =>
    let t := match decodeField j "title" with | some (.str s) => some s | _ => none
    let d := match decodeField j "description" with | some (.str s) => some s | _ => none
    let c := match decodeField j "completed" with | some (.bool b) => some b | _ => none
    some { title := t, description := d, completed := c }

-- Authentication helper

def authUser (stVar : SharedState) (hdrs : HashMap String String) : IO (Except Response Nat) := do
  let cookies := parseCookies hdrs
  match cookies.find? "session_id" with
  | none =>
    let resp := { Response . status := 401, reason := "Unauthorized", headers := #[("Content-Type","application/json")], body := encodeJson (jsonError "Authentication required") }
    return .error resp
  | some tok =>
    let st ← stVar.read
    match st.sessions.find? tok with
    | none =>
      let resp := { Response . status := 401, reason := "Unauthorized", headers := #[("Content-Type","application/json")], body := encodeJson (jsonError "Authentication required") }
      return .error resp
    | some uid => return .ok uid

-- Core request handler

def handle (stVar : SharedState) (req : Request) : IO Response := do
  let method := req.method
  let path := req.path
  -- routing
  if method == "POST" && path == "/register" then
    match parseRegister req.body with
    | none => return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Invalid username") }
    | some r =>
      if !isValidUsername r.username then
        return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Invalid username") }
      if r.password.length < 8 then
        return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Password too short") }
      let resp ← stVar.modifyGet fun st =>
        if st.usersByName.contains r.username then
          let resp := { Response . status := 409, reason := "Conflict", headers := #[], body := encodeJson (jsonError "Username already exists") }
          (resp, st)
        else
          let uid := st.nextUserId
          let ur : UserRecord := { id := uid, username := r.username, password := r.password }
          let st' : AppState := { st with
            nextUserId := uid + 1
            usersByName := st.usersByName.insert r.username ur
            usersById := st.usersById.insert uid ur
          }
          let userJson := Lean.Json.mkObj [("id", Lean.Json.num uid), ("username", Lean.Json.str r.username)]
          let resp := { Response . status := 201, reason := "Created", headers := #[], body := encodeJson userJson }
          (resp, st')
      return resp
  else if method == "POST" && path == "/login" then
    match parseLogin req.body with
    | none => return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
    | some r =>
      let (ok, ur?) ← stVar.modifyGet fun st =>
        match st.usersByName.find? r.username with
        | some ur => if ur.password == r.password then ((true, some ur), st) else ((false, none), st)
        | none => ((false, none), st)
      if !ok then
        return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
      let some ur := ur? | return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
      let tok ← newSessionToken
      let _ ← stVar.modify fun st => { st with sessions := st.sessions.insert tok ur.id }
      let userJson := Lean.Json.mkObj [("id", Lean.Json.num ur.id), ("username", Lean.Json.str ur.username)]
      let headers := #[("Set-Cookie", s!"session_id={tok}; Path=/; HttpOnly")]
      return { status := 200, reason := "OK", headers, body := encodeJson userJson }
  else if method == "POST" && path == "/logout" then
    match (← authUser stVar req.headers) with
    | .error resp => return resp
    | .ok uid =>
      -- get token to invalidate
      let cookies := parseCookies req.headers
      let some tok := cookies.find? "session_id" | return { status := 200, reason := "OK", headers := #[], body := encodeJson (Lean.Json.obj .empty) }
      let _ ← stVar.modify fun st => { st with sessions := st.sessions.erase tok }
      return { status := 200, reason := "OK", headers := #[], body := encodeJson (Lean.Json.obj .empty) }
  else if method == "GET" && path == "/me" then
    match (← authUser stVar req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let st ← stVar.read
      match getUserById st uid with
      | some u =>
        let j := Lean.Json.mkObj [("id", Lean.Json.num u.id), ("username", Lean.Json.str u.username)]
        return { status := 200, reason := "OK", headers := #[], body := encodeJson j }
      | none =>
        return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Authentication required") }
  else if method == "PUT" && path == "/password" then
    match (← authUser stVar req.headers) with
    | .error resp => return resp
    | .ok uid =>
      match parsePassword req.body with
      | none => return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Password too short") }
      | some pr =>
        if pr.new_password.length < 8 then
          return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Password too short") }
        let ok ← stVar.modifyGet fun st =>
          match st.usersById.find? uid with
          | some ur =>
            if ur.password != pr.old_password then
              (false, st)
            else
              let ur' := { ur with password := pr.new_password }
              let st' := { st with
                usersById := st.usersById.insert uid ur'
                usersByName := st.usersByName.insert ur.username ur'
              }
              (true, st')
          | none => (false, st)
        if !ok then
          return { status := 401, reason := "Unauthorized", headers := #[], body := encodeJson (jsonError "Invalid credentials") }
        else
          return { status := 200, reason := "OK", headers := #[], body := encodeJson (Lean.Json.obj .empty) }
  else if method == "GET" && path == "/todos" then
    match (← authUser stVar req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let st ← stVar.read
      let ids := st.userTodoIds.findD uid #[]
      let mut arr : Array Lean.Json := #[]
      for id in ids do
        match st.todosById.find? id with
        | some t => arr := arr.push (todoPublicJson t)
        | none => pure ()
      let j := Lean.Json.arr arr
      return { status := 200, reason := "OK", headers := #[], body := encodeJson j }
  else if method == "POST" && path == "/todos" then
    match (← authUser stVar req.headers) with
    | .error resp => return resp
    | .ok uid =>
      match parseCreateTodo req.body with
      | none => return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Title is required") }
      | some r =>
        if r.title.trim == "" then
          return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Title is required") }
        let now ← nowIsoUtc
        let resp ← stVar.modifyGet fun st =>
          let tid := st.nextTodoId
          let t : TodoItem := { id := tid, ownerId := uid, title := r.title, description := r.description.getD "", completed := false, created_at := now, updated_at := now }
          let st' := { st with
            nextTodoId := tid + 1
            todosById := st.todosById.insert tid t
            userTodoIds := st.userTodoIds.insert uid ((st.userTodoIds.findD uid #[]).push tid)
          }
          let resp := { Response . status := 201, reason := "Created", headers := #[], body := encodeJson (todoPublicJson t) }
          (resp, st')
        return resp
  else if method == "GET" && path.startsWith "/todos/" then
    match (← authUser stVar req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let sid := path.drop "/todos/".length
      match sid.toNat? with
      | none => return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
      | some tid =>
        let st ← stVar.read
        match st.todosById.find? tid with
        | some t =>
          if t.ownerId != uid then
            return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
          else
            return { status := 200, reason := "OK", headers := #[], body := encodeJson (todoPublicJson t) }
        | none => return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
  else if method == "PUT" && path.startsWith "/todos/" then
    match (← authUser stVar req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let sid := path.drop "/todos/".length
      match sid.toNat? with
      | none => return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
      | some tid =>
        match parseUpdateTodo req.body with
        | none => return { status := 200, reason := "OK", headers := #[], body := encodeJson (Lean.Json.obj .empty) } -- shouldn't happen
        | some ureq =>
          if let some t := ureq.title then
            if t.trim == "" then
              return { status := 400, reason := "Bad Request", headers := #[], body := encodeJson (jsonError "Title is required") }
          let now ← nowIsoUtc
          let foundAndOwned ← stVar.modifyGet fun st =>
            match st.todosById.find? tid with
            | none => ((false, none), st)
            | some t =>
              if t.ownerId != uid then
                ((false, some t), st)
              else
                let t' := { t with
                  title := ureq.title.getD t.title
                  description := ureq.description.getD t.description
                  completed := ureq.completed.getD t.completed
                  updated_at := now
                }
                let st' := { st with todosById := st.todosById.insert tid t' }
                ((true, some t'), st')
          match foundAndOwned with
          | (false, _) => return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Todo not found") }
          | (true, some t') => return { status := 200, reason := "OK", headers := #[], body := encodeJson (todoPublicJson t') }
          | _ => return { status := 500, reason := "Internal Server Error", headers := #[], body := encodeJson (jsonError "Internal error") }
  else if method == "DELETE" && path.startsWith "/todos/" then
    match (← authUser stVar req.headers) with
    | .error resp => return resp
    | .ok uid =>
      let sid := path.drop "/todos/".length
      match sid.toNat? with
      | none => return { status := 404, reason := "Not Found", headers := #[], body := ByteArray.empty }
      | some tid =>
        let ok ← stVar.modifyGet fun st =>
          match st.todosById.find? tid with
          | none => (false, st)
          | some t =>
            if t.ownerId != uid then (false, st) else
            let st1 := { st with todosById := st.todosById.erase tid }
            let ids := st1.userTodoIds.findD uid #[]
            let ids' := ids.filter (· != tid)
            let st2 := { st1 with userTodoIds := st1.userTodoIds.insert uid ids' }
            (true, st2)
        if !ok then
          return { status := 404, reason := "Not Found", headers := #[], body := ByteArray.empty }
        else
          -- 204 No Content, and MUST have no body
          return { status := 204, reason := "No Content", headers := #[("Content-Length","0")], body := ByteArray.empty }
  else
    return { status := 404, reason := "Not Found", headers := #[], body := encodeJson (jsonError "Not found") }

-- Server loop

def handleClient (stVar : SharedState) (sock : Socket) : IO Unit := do
  let req? ← Http.readRequest sock
  match req? with
  | none => pure ()
  | some req =>
    let resp ← handle stVar req
    let bytes := Http.renderResponse resp
    let _ ← sock.send bytes
    pure ()
  finally sock.close

-- Main entry: parse --port and run

def parsePort (args : List String) : Nat :=
  let rec go (as : List String) (p : Nat) : Nat :=
    match as with
    | [] => p
    | "--port"::v::rest =>
      match v.toNat? with
      | some n => go rest n
      | none => go rest p
    | _::rest => go rest p
  go args 8080

def startServer (port : Nat) : IO Unit := do
  let stVar ← MVar.mk (default : AppState)
  let addr := Socket.Address.v4 0 0 0 0 (port := port.toUInt16!)
  let sock ← Socket.mk Socket.Family.inet Socket.Type.stream Socket.Protocol.tcp
  try
    sock.setOption Socket.Option.reuseAddr true
    sock.bind addr
    sock.listen 128
    IO.println s!"Server listening on 0.0.0.0:{port}"
    let rec acceptLoop : IO Unit := do
      let (client, _) ← sock.accept
      -- spawn a task per client
      let _ ← IO.asTask (handleClient stVar client) Task.Priority.dedicated
      acceptLoop
    acceptLoop
  finally
    sock.close

end Todo

open Todo in
def main : IO Unit := do
  let args ← IO.getArgs
  let port := Todo.parsePort args.toList
  Todo.startServer port
