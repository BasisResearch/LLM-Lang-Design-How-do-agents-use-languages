import LeanHTTP
import Lean.Data.Json
import Init.System.IO

open LeanHTTP
open Lean

def byteArrayToString (ba : ByteArray) : String :=
  String.mk (ba.toList.map fun b => Char.ofNat b.toNat)

def escapeJson (s : String) : String :=
  s.replace "\\" "\\\\" |>.replace "\"" "\\\""

structure User where
  id : Nat
  username : String
  password : String

structure Todo where
  id : Nat
  userId : Nat
  title : String
  description : String
  completed : Bool
  createdAt : String
  updatedAt : String

def todoToJson (t : Todo) : String :=
  let compStr := if t.completed then "true" else "false"
  let escTitle := escapeJson t.title
  let escDesc := escapeJson t.description
  "{\"id\":" ++ toString t.id ++ ",\"title\":\"" ++ escTitle ++ "\",\"description\":\"" ++ escDesc ++ "\",\"completed\":" ++ compStr ++ ",\"created_at\":\"" ++ t.createdAt ++ "\",\"updated_at\":\"" ++ t.updatedAt ++ "\"}"

def userToJson (u : User) : String :=
  let escUser := escapeJson u.username
  "{\"id\":" ++ toString u.id ++ ",\"username\":\"" ++ escUser ++ "\"}"

def generateToken : IO String := do
  let now ← IO.monoNanosNow
  let randVal ← IO.rand 0 999999
  return "token_" ++ toString now ++ "_" ++ toString randVal

def getCurrentTimestamp : IO String := do
  return "2025-01-15T12:00:00Z"

def jsonResp (body : String) : HttpResponse := HttpResponse.json 200 body
def json400 (msg : String) : HttpResponse := HttpResponse.json 400 msg
def json401 (msg : String) : HttpResponse := HttpResponse.json 401 msg
def json404 (msg : String) : HttpResponse := HttpResponse.json 404 msg
def json409 (msg : String) : HttpResponse := HttpResponse.json 409 msg
def json201 (body : String) : HttpResponse := HttpResponse.json 201 body
def json204 : HttpResponse := HttpResponse.noContent

def setCookieResp (token : String) (body : String) : HttpResponse :=
  HttpResponse.json 200 body |>.setCookie "session_id" token {httpOnly := true, path := some "/"}

def clearCookieResp : HttpResponse :=
  let opts : CookieOptions := {httpOnly := true, path := some "/", maxAge := some 0}
  HttpResponse.json 200 "{}" |>.setCookie "session_id" "" opts

def getStr (j : Json) (k : String) : Option String :=
  match j.getObjVal? k with
  | .ok (.str s) => some s
  | _ => none

def getBool (j : Json) (k : String) : Option Bool :=
  match j.getObjVal? k with
  | .ok (.bool b) => some b
  | _ => none

-- Our internal state
structure AppState where
  users : List User := []
  todos : List Todo := []
  sessions : List (String × Nat) := []
  nextUserId : Nat := 1
  nextTodoId : Nat := 1

def handleRequest (stateRef : IO.Ref AppState) (req : HttpRequest) : IO HttpResponse := do
  let state ← stateRef.get
  let bodyStr := byteArrayToString req.body
  
  if req.path == "/register" && req.method == .POST then
    match Json.parse bodyStr with
    | .ok j =>
      match getStr j "username", getStr j "password" with
      | some u, some p =>
        if u.length < 3 || u.length > 50 || !(u.all (fun c => c.isAlpha || c.isDigit || c == '_')) then
          return json400 "{\"error\":\"Invalid username\"}"
        if p.length < 8 then
          return json400 "{\"error\":\"Password too short\"}"
        if state.users.any (fun x => x.username == u) then
          return json409 "{\"error\":\"Username already exists\"}"
        
        let newUser := { id := state.nextUserId, username := u, password := p }
        stateRef.set { state with users := newUser :: state.users, nextUserId := state.nextUserId + 1 }
        return json201 (userToJson newUser)
      | _, _ => return json400 "{\"error\":\"Invalid request\"}"
    | _ => return json400 "{\"error\":\"Invalid request\"}"

  else if req.path == "/login" && req.method == .POST then
    match Json.parse bodyStr with
    | .ok j =>
      match getStr j "username", getStr j "password" with
      | some u, some p =>
        match state.users.find? (fun x => x.username == u && x.password == p) with
        | some user =>
          let token ← generateToken
          stateRef.set { state with sessions := (token, user.id) :: state.sessions }
          return setCookieResp token (userToJson user)
        | none => return json401 "{\"error\":\"Invalid credentials\"}"
      | _, _ => return json400 "{\"error\":\"Invalid request\"}"
    | _ => return json400 "{\"error\":\"Invalid request\"}"

  else
    match req.cookie "session_id" with
    | none => return json401 "{\"error\":\"Authentication required\"}"
    | some t =>
      match state.sessions.find? (fun (tok, _) => tok == t) with
      | none => return json401 "{\"error\":\"Authentication required\"}"
      | some (_, userId) =>
        match state.users.find? (fun u => u.id == userId) with
        | none => return json401 "{\"error\":\"Authentication required\"}"
        | some user =>
          if req.path == "/logout" && req.method == .POST then
            let newSessions := state.sessions.filter (fun (tok, _) => tok != t)
            stateRef.set { state with sessions := newSessions }
            return clearCookieResp
          
          else if req.path == "/me" && req.method == .GET then
            return jsonResp (userToJson user)
          
          else if req.path == "/password" && req.method == .PUT then
            match Json.parse bodyStr with
            | .ok j =>
              match getStr j "old_password", getStr j "new_password" with
              | some op, some np =>
                if op != user.password then
                  return json401 "{\"error\":\"Invalid credentials\"}"
                if np.length < 8 then
                  return json400 "{\"error\":\"Password too short\"}"
                let updatedUser := { user with password := np }
                let newUsers := state.users.map (fun u => if u.id == userId then updatedUser else u)
                stateRef.set { state with users := newUsers }
                return jsonResp "{}"
              | _, _ => return json400 "{\"error\":\"Invalid request\"}"
            | _ => return json400 "{\"error\":\"Invalid request\"}"

          else if req.path == "/todos" && req.method == .GET then
            let userTodos := state.todos.filter (fun t => t.userId == userId)
            let jsonArr : String := "[" ++ (userTodos.map todoToJson |>.foldl (fun acc s => if acc == "" then s else acc ++ "," ++ s) "") ++ "]"
            return jsonResp jsonArr

          else if req.path == "/todos" && req.method == .POST then
            match Json.parse bodyStr with
            | .ok j =>
              match getStr j "title" with
              | some t =>
                if t.isEmpty then
                  return json400 "{\"error\":\"Title is required\"}"
                let descStr := getStr j "description" |>.getD ""
                let now ← getCurrentTimestamp
                let newTodo := {
                  id := state.nextTodoId,
                  userId := userId,
                  title := t,
                  description := descStr,
                  completed := false,
                  createdAt := now,
                  updatedAt := now
                }
                stateRef.set { state with todos := newTodo :: state.todos, nextTodoId := state.nextTodoId + 1 }
                return json201 (todoToJson newTodo)
              | none => return json400 "{\"error\":\"Title is required\"}"
            | _ => return json400 "{\"error\":\"Invalid request\"}"

          else if req.path.startsWith "/todos/" && req.method == .GET then
            let idStr := req.path.drop 7
            match String.toNat? idStr with
            | some todoId =>
              match state.todos.find? (fun t => t.id == todoId && t.userId == userId) with
              | some t => return jsonResp (todoToJson t)
              | none => return json404 "{\"error\":\"Todo not found\"}"
            | none => return json404 "{\"error\":\"Todo not found\"}"

          else if req.path.startsWith "/todos/" && req.method == .PUT then
            let idStr := req.path.drop 7
            match String.toNat? idStr with
            | some todoId =>
              match state.todos.find? (fun t => t.id == todoId && t.userId == userId) with
              | some t =>
                match Json.parse bodyStr with
                | .ok j =>
                  let newTitle := getStr j "title"
                  let newDesc := getStr j "description"
                  let newCompleted := getBool j "completed"
                  
                  if newTitle.isSome && newTitle.getD "" == "" then
                    return json400 "{\"error\":\"Title is required\"}"
                  
                  let now ← getCurrentTimestamp
                  let updated := {
                    t with
                    title := newTitle.getD t.title,
                    description := newDesc.getD t.description,
                    completed := newCompleted.getD t.completed,
                    updatedAt := now
                  }
                  let newTodos := state.todos.map (fun todo => if todo.id == todoId then updated else todo)
                  stateRef.set { state with todos := newTodos }
                  return jsonResp (todoToJson updated)
                | _ => 
                  let now ← getCurrentTimestamp
                  let updated := { t with updatedAt := now }
                  let newTodos := state.todos.map (fun todo => if todo.id == todoId then updated else todo)
                  stateRef.set { state with todos := newTodos }
                  return jsonResp (todoToJson updated)
              | none => return json404 "{\"error\":\"Todo not found\"}"
            | none => return json404 "{\"error\":\"Todo not found\"}"

          else if req.path.startsWith "/todos/" && req.method == .DELETE then
            let idStr := req.path.drop 7
            match String.toNat? idStr with
            | some todoId =>
              match state.todos.find? (fun t => t.id == todoId && t.userId == userId) with
              | some _ =>
                let newTodos := state.todos.filter (fun t => t.id != todoId)
                stateRef.set { state with todos := newTodos }
                return json204
              | none => return json404 "{\"error\":\"Todo not found\"}"
            | none => return json404 "{\"error\":\"Todo not found\"}"

          else
            return json404 "{\"error\":\"Not found\"}"

def getPort : IO UInt16 := do
  match ← IO.getEnv "PORT" with
  | some p => 
    match String.toNat? p with
    | some n => return n.toUInt16
    | none => return 8080
  | none => return 8080

def main : IO Unit := do
  let port ← getPort
  let stateRef ← IO.mkRef { AppState }
  
  let r ← Router.new
  
  r.post "/register" (fun req => handleRequest stateRef req)
  r.post "/login" (fun req => handleRequest stateRef req)
  r.post "/logout" (fun req => handleRequest stateRef req)
  r.get "/me" (fun req => handleRequest stateRef req)
  r.put "/password" (fun req => handleRequest stateRef req)
  r.get "/todos" (fun req => handleRequest stateRef req)
  r.post "/todos" (fun req => handleRequest stateRef req)
  r.get "/todos/*" (fun req => handleRequest stateRef req)
  r.put "/todos/*" (fun req => handleRequest stateRef req)
  r.delete "/todos/*" (fun req => handleRequest stateRef req)

  IO.println ("Server listening on 0.0.0.0:" ++ toString port)
  r.listen port