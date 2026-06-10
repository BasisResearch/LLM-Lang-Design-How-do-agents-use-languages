import Lean
import Lean.Data.Json

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
  created_at : String
  updated_at : String
  deriving Repr

structure State where
  nextUserId : Nat := 1
  nextTodoId : Nat := 1
  users : List User := []
  sessions : List (String × Nat) := [] -- token -> userId
  todos : List Todo := []
  deriving Inhabited

abbrev ServerState := MVar State

namespace JsonUtil

open Lean

def jsonObj (kvs : List (String × Json)) : Json :=
  let m := kvs.foldl (init := RBMap.empty) (fun acc (k,v) => acc.insert k v (fun a b => compare a b))
  Json.obj m

def okObj : Json := jsonObj []

instance : ToJson User where
  toJson u := jsonObj [
    ("id", Json.num u.id),
    ("username", Json.str u.username)
  ]

instance : ToJson Todo where
  toJson t := jsonObj [
    ("id", Json.num t.id),
    ("title", Json.str t.title),
    ("description", Json.str t.description),
    ("completed", Json.bool t.completed),
    ("created_at", Json.str t.created_at),
    ("updated_at", Json.str t.updated_at)
  ]

end JsonUtil

namespace Util

open IO

def isValidUsername (s : String) : Bool :=
  let n := s.length
  if n < 3 || n > 50 then false
  else s.all fun c => c.isAlphanum || c == '_'

def nowIsoUtc : IO String := do
  let child ← IO.Process.spawn {
    cmd := "date",
    args := # ["-u", "+%Y-%m-%dT%H:%M:%SZ"],
    stdout := .piped,
    stderr := .piped
  }
  let out ← child.stdout.readToEnd
  let _ ← child.wait
  pure out.trim

private unsafe def tokenCounter : IO.Ref Nat := unsafePerformIO <| IO.mkRef 0
@[implementedBy tokenCounter]
constant tokenCounter : IO.Ref Nat

def genToken : IO String := do
  let t ← IO.monoMsNow
  let c ← tokenCounter.modifyGet (fun x => (x+1, x+1))
  pure s!"{(t.toNat + c).toString}{c}"

end Util

structure Request where
  method : String
  path : String
  headers : List (String × String) -- lowercased keys
  body : ByteArray
  deriving Repr

structure Response where
  status : Nat
  statusText : String
  headers : List (String × String)
  body : ByteArray

namespace Http

open JsonUtil

private def lower (s : String) := s.map Char.toLower

private def findHeader? (hs : List (String × String)) (name : String) : Option String :=
  let lname := lower name
  hs.findSome? (fun (k,v) => if k == lname then some v else none)

private def parseHeaders (s : String) : List (String × String) :=
  let lines := s.splitOn "\r\n"
  let rec loop (ls : List String) (acc : List (String × String)) :=
    match ls with
    | [] => acc
    | l::rest =>
      if l.isEmpty then acc
      else
        match l.splitOn ":" with
        | [] => loop rest acc
        | k::vs =>
          let v := (String.intercalate ":" vs).trim
          loop rest ((lower k, v)::acc)
  loop (lines.drop 1) [] |>.reverse

private def indexOfSub (ba : ByteArray) (pat : ByteArray) : Option Nat :=
  let n := ba.size; let m := pat.size
  if m == 0 then some 0 else
  let rec go (i : Nat) : Option Nat :=
    if i + m > n then none
    else
      let seg := ba.extract i (i+m)
      if seg == pat then some i else go (i+1)
  go 0

def parseRawRequest (raw : ByteArray) : Request :=
  let sep := ByteArray.mk #[13,10,13,10] -- CRLFCRLF
  match indexOfSub raw sep with
  | none => { method := "", path := "/", headers := [], body := ByteArray.empty }
  | some i =>
    let hdrBytes := raw.extract 0 i
    let body := raw.extract (i+4) raw.size
    let headerStr := String.fromUTF8Unchecked hdrBytes
    let first := headerStr.splitOn "\r\n" |>.headD ""
    let parts := first.splitOn " "
    let method := parts.getD 0 ""
    let path := parts.getD 1 "/"
    let headers := parseHeaders headerStr
    let clen :=
      match findHeader? headers "content-length" with
      | some v => v.trim.toNat?.getD 0
      | none => 0
    let body := if clen > 0 then body.extract 0 clen else body
    { method, path, headers, body }

def buildHttpBytes (resp : Response) : ByteArray :=
  let sb := String.build (fun b => do
    b.append s!"HTTP/1.1 {resp.status} {resp.statusText}\r\n"
    for (k,v) in resp.headers do
      b.append s!"{k}: {v}\r\n"
    b.append "Connection: close\r\n"
    b.append "\r\n"
  )
  sb.toString.toUTF8 ++ resp.body

namespace Resp

open JsonUtil

def mk (status : Nat) (statusText : String) (json? : Option Json) (extraHeaders : List (String × String) := []) : Response :=
  match json? with
  | some j =>
    let bodyStr := toString j
    let body := bodyStr.toUTF8
    let headers := [
      ("Content-Type", "application/json"),
      ("Content-Length", toString body.size)
    ] ++ extraHeaders
    { status, statusText, headers, body }
  | none =>
    { status, statusText, headers := extraHeaders, body := ByteArray.empty }

def ok (j : Json) : Response := mk 200 "OK" (some j)

def created (j : Json) : Response := mk 201 "Created" (some j)

def noContent : Response := mk 204 "No Content" none []

def badRequest (msg : String) : Response :=
  mk 400 "Bad Request" (some <| jsonObj [("error", Json.str msg)])

def unauthorized : Response :=
  mk 401 "Unauthorized" (some <| jsonObj [("error", Json.str "Authentication required")])

def unauthorizedCreds : Response :=
  mk 401 "Unauthorized" (some <| jsonObj [("error", Json.str "Invalid credentials")])

def conflict (msg : String) : Response := mk 409 "Conflict" (some <| jsonObj [("error", Json.str msg)])

def notFound (msg : String) : Response := mk 404 "Not Found" (some <| jsonObj [("error", Json.str msg)])

end Resp

open JsonUtil Util Resp

structure Authed where
  user : User
  token : String

private def getCookie (headers : List (String × String)) (name : String) : Option String :=
  match headers.find? (fun (k,_) => k == "cookie") with
  | none => none
  | some (_,v) =>
    let parts := v.splitOn ";"
    let rec loop : List String → Option String
    | [] => none
    | p::rest =>
      let p := p.trim
      match p.splitOn "=" with
      | [n, val] => if n = name then some val else loop rest
      | _ => loop rest
    loop parts

partial def handleRequest (st : ServerState) (req : Request) : IO Response := do
  let path := req.path.splitOn "?" |>.head!
  let getAuthed : IO (Except Response Authed) := do
    let some token := getCookie req.headers "session_id" | return .error Resp.unauthorized
    let s ← st.take
    let uid? := (s.sessions.find? (fun (t,_) => t = token)).map (·.2)
    let u? := uid?.bind (fun uid => s.users.find? (fun u => u.id == uid))
    st.put s
    match u? with
    | some u => pure (.ok { user := u, token := token })
    | none => pure (.error Resp.unauthorized)
  match (req.method, path) with
  | ("POST", "/register") => do
    let bodyStr := String.fromUTF8Unchecked req.body
    let some j := Json.parse bodyStr |>.toOption | return Resp.badRequest "Invalid JSON"
    let username := j.getObjValAs? String "username" |>.toOption |>.getD ""
    let password := j.getObjValAs? String "password" |>.toOption |>.getD ""
    if !Util.isValidUsername username then
      return Resp.badRequest "Invalid username"
    if password.length < 8 then
      return Resp.mk 400 "Bad Request" (some <| jsonObj [("error", Json.str "Password too short")])
    let s ← st.take
    if s.users.any (fun u => u.username = username) then
      st.put s; return Resp.conflict "Username already exists"
    let uid := s.nextUserId
    let u : User := { id := uid, username, password }
    let s' : State := { s with nextUserId := uid + 1, users := s.users ++ [u] }
    st.put s'
    return Resp.created (toJson u)
  | ("POST", "/login") => do
    let bodyStr := String.fromUTF8Unchecked req.body
    let some j := Json.parse bodyStr |>.toOption | return Resp.badRequest "Invalid JSON"
    let username := j.getObjValAs? String "username" |>.toOption |>.getD ""
    let password := j.getObjValAs? String "password" |>.toOption |>.getD ""
    let s ← st.take
    match s.users.find? (fun u => u.username = username) with
    | none => st.put s; return Resp.unauthorizedCreds
    | some u =>
      if u.password ≠ password then
        st.put s; return Resp.unauthorizedCreds
      else
        let token ← Util.genToken
        let s' := { s with sessions := s.sessions ++ [(token, u.id)] }
        st.put s'
        return Resp.mk 200 "OK" (some <| toJson u) [("Set-Cookie", s!"session_id={token}; Path=/; HttpOnly")]
  | ("POST", "/logout") => do
    match ← getAuthed with
    | .error r => return r
    | .ok a =>
      let s ← st.take
      let sess' := s.sessions.filter (fun (t,_) => t ≠ a.token)
      st.put { s with sessions := sess' }
      return Resp.ok okObj
  | ("GET", "/me") => do
    match ← getAuthed with
    | .error r => return r
    | .ok a => return Resp.ok (toJson a.user)
  | ("PUT", "/password") => do
    match ← getAuthed with
    | .error r => return r
    | .ok a =>
      let bodyStr := String.fromUTF8Unchecked req.body
      let some j := Json.parse bodyStr |>.toOption | return Resp.badRequest "Invalid JSON"
      let oldp := j.getObjValAs? String "old_password" |>.toOption |>.getD ""
      let newp := j.getObjValAs? String "new_password" |>.toOption |>.getD ""
      if newp.length < 8 then
        return Resp.mk 400 "Bad Request" (some <| jsonObj [("error", Json.str "Password too short")])
      let s ← st.take
      match s.users.find? (fun u => u.id == a.user.id) with
      | none => st.put s; return Resp.unauthorizedCreds
      | some u =>
        if u.password ≠ oldp then
          st.put s; return Resp.unauthorizedCreds
        else
          let users' := s.users.map (fun uu => if uu.id == u.id then { uu with password := newp } else uu)
          st.put { s with users := users' }
          return Resp.ok okObj
  | _ =>
    if path.startsWith "/todos" then
      match ← getAuthed with
      | .error r => return r
      | .ok a =>
        if path == "/todos" then
          match req.method with
          | "GET" => do
            let s ← st.take
            let todos := s.todos.filter (fun t => t.userId == a.user.id)
            let sorted := todos.qsort (fun t1 t2 => t1.id < t2.id)
            let arr := sorted.map (fun t => toJson t)
            st.put s
            return Resp.ok (Json.arr arr)
          | "POST" => do
            let bodyStr := String.fromUTF8Unchecked req.body
            let some j := Json.parse bodyStr |>.toOption | return Resp.badRequest "Invalid JSON"
            let title? := j.getObjValAs? String "title" |>.toOption
            let desc := j.getObjValAs? String "description" |>.toOption |>.getD ""
            match title? with
            | none => return Resp.mk 400 "Bad Request" (some <| jsonObj [("error", Json.str "Title is required")])
            | some t =>
              if t.trim.isEmpty then
                return Resp.mk 400 "Bad Request" (some <| jsonObj [("error", Json.str "Title is required")])
              let created ← Util.nowIsoUtc
              let s ← st.take
              let tid := s.nextTodoId
              let todo : Todo := { id := tid, userId := a.user.id, title := t, description := desc, completed := false, created_at := created, updated_at := created }
              st.put { s with nextTodoId := tid+1, todos := s.todos ++ [todo] }
              return Resp.created (toJson todo)
          | _ => return Resp.badRequest "Unsupported method"
        else
          let parts := path.splitOn "/"
          let idStr? := parts.getLast?
          let some idStr := idStr? | return Resp.notFound "Todo not found"
          let some id := idStr.toNat? | return Resp.notFound "Todo not found"
          match req.method with
          | "GET" => do
            let s ← st.take
            match s.todos.find? (fun t => t.id == id) with
            | some t =>
              st.put s
              if t.userId == a.user.id then return Resp.ok (toJson t) else return Resp.notFound "Todo not found"
            | none => st.put s; return Resp.notFound "Todo not found"
          | "PUT" => do
            let bodyStr := String.fromUTF8Unchecked req.body
            let some j := Json.parse bodyStr |>.toOption | return Resp.badRequest "Invalid JSON"
            let s ← st.take
            match s.todos.find? (fun t => t.id == id) with
            | none => st.put s; return Resp.notFound "Todo not found"
            | some t =>
              if t.userId ≠ a.user.id then
                st.put s; return Resp.notFound "Todo not found"
              else
                let title? := j.getObjValAs? String "title" |>.toOption
                match title? with
                | some t' => if t'.trim.isEmpty then st.put s; return Resp.mk 400 "Bad Request" (some <| jsonObj [("error", Json.str "Title is required")]) else pure ()
                | none => pure ()
                let desc? := j.getObjValAs? String "description" |>.toOption
                let comp? := j.getObjValAs? Bool "completed" |>.toOption
                let updated ← Util.nowIsoUtc
                let t' := { t with
                  title := title?.getD t.title,
                  description := desc?.getD t.description,
                  completed := comp?.getD t.completed,
                  updated_at := updated
                }
                let todos' := s.todos.map (fun x => if x.id == id then t' else x)
                st.put { s with todos := todos' }
                return Resp.ok (toJson t')
          | "DELETE" => do
            let s ← st.take
            match s.todos.find? (fun t => t.id == id) with
            | none => st.put s; return Resp.notFound "Todo not found"
            | some t =>
              if t.userId ≠ a.user.id then
                st.put s; return Resp.notFound "Todo not found"
              else
                let todos' := s.todos.filter (fun x => x.id ≠ id)
                st.put { s with todos := todos' }
                return Resp.noContent
          | _ => return Resp.badRequest "Unsupported method"
    else
      return Resp.badRequest "Unsupported path"

end Http

