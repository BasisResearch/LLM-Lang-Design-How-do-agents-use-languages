import LeanHTTP
import Std.Data.HashMap

open LeanHTTP
open Std

set_option warningAsError false

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

structure AppState where
  nextUserId : Nat := 1
  nextTodoId : Nat := 1
  users : HashMap String User
  sessions : HashMap String Nat
  todos : HashMap Nat Todo

def getTimestamp : IO String := do
  let res ← IO.Process.output { cmd := "date", args := #["+%Y-%m-%dT%H:%M:%SZ"], env := #[] }
  match res.stdout.splitOn "\n" with
  | x :: _ => return x
  | [] => return res.stdout

def isBlank (s : String) : Bool :=
  s.trimAscii.toString == ""

def extractStr (json : String) (key : String) : Option String :=
  let parts := json.splitOn "\""
  let rec findKey (idx : Nat) : Option String :=
    if idx + 2 >= parts.length then none
    else if parts[idx]! == key then
      some (parts[idx+2]!)
    else findKey (idx + 1)
  findKey 0

def extractBool (json : String) (key : String) : Option Bool :=
  let searchKey := "\"" ++ key ++ "\":"
  if json.contains searchKey then
    let rest := json.splitOn searchKey
    if rest.length > 1 then
      let tail := rest[1]!
      if tail.trimAscii.toString.startsWith "true" then some true
      else if tail.trimAscii.toString.startsWith "false" then some false
      else none
    else none
  else none

def makeHandlers (stateRef : IO.Ref AppState) : IO Router := do
  let requireAuth (req : HttpRequest) : IO (Option Nat) := do
    let header := req.headers.find? (fun (k, _) => k.toLower == "cookie")
    let cookieStr := header.map (fun (_, v) => v)
    let tokenOpt := cookieStr >>= fun c => 
      let parts := c.splitOn ";"
      parts.find? (fun p => p.trimAscii.toString.startsWith "session_id=") |>.map (fun p => p.trimAscii.drop 11 |>.toString)
    match tokenOpt with
    | none => return none
    | some token =>
      let state ← stateRef.get
      match state.sessions.get? token with
      | none => return none
      | some userId => return some userId

  let jsonError (status : Nat) (msg : String) : HttpResponse :=
    let bodyStr := "{\"error\": \"" ++ msg ++ "\"}"
    {
      status := status
      statusText := if status == 400 then "Bad Request" else if status == 401 then "Unauthorized" else if status == 404 then "Not Found" else if status == 409 then "Conflict" else "Error"
      headers := #[("Content-Type", "application/json"), ("Content-Length", toString bodyStr.length)]
      body := bodyStr.toUTF8
    }

  let jsonSuccess (status : Nat) (bodyStr : String) : HttpResponse :=
    {
      status := status
      statusText := if status == 200 then "OK" else if status == 201 then "Created" else "Success"
      headers := #[("Content-Type", "application/json"), ("Content-Length", toString bodyStr.length)]
      body := bodyStr.toUTF8
    }

  let jsonSuccessNoBody (status : Nat) : HttpResponse :=
    {
      status := status
      statusText := if status == 204 then "No Content" else "Success"
      headers := #[]
      body := ByteArray.empty
    }

  let userToJson (u : User) : String :=
    "{\"id\": " ++ toString u.id ++ ", \"username\": \"" ++ u.username ++ "\"}"

  let todoToJson (t : Todo) : String :=
    "{\"id\": " ++ toString t.id ++ ", \"title\": \"" ++ t.title ++ "\", \"description\": \"" ++ t.description ++ "\", \"completed\": " ++ (if t.completed then "true" else "false") ++ ", \"created_at\": \"" ++ t.createdAt ++ "\", \"updated_at\": \"" ++ t.updatedAt ++ "\"}"

  let handleRegister : Handler := fun req => do
    let reqStr := String.fromUTF8! req.body
    let uname := extractStr reqStr "username"
    let pwd := extractStr reqStr "password"
    match uname, pwd with
    | none, _ => return jsonError 400 "Invalid username"
    | _, none => return jsonError 400 "Password too short"
    | some u, some p =>
      if !(u.length >= 3 && u.length <= 50) || !(u.all (fun c => c.isAlpha || c.isDigit || c.toNat == 95)) then
        return jsonError 400 "Invalid username"
      if p.length < 8 then
        return jsonError 400 "Password too short"
      
      let state ← stateRef.get
      if state.users.contains u then
        return jsonError 409 "Username already exists"
      
      let newUser : User := {
        id := state.nextUserId
        username := u
        password := p
      }
      stateRef.modify fun s => {
        s with
        nextUserId := s.nextUserId + 1
        users := s.users.insert u newUser
      }
      return jsonSuccess 201 (userToJson newUser)

  let handleLogin : Handler := fun req => do
    let reqStr := String.fromUTF8! req.body
    let uname := extractStr reqStr "username"
    let pwd := extractStr reqStr "password"
    match uname, pwd with
    | none, _ | _, none => return jsonError 401 "Invalid credentials"
    | some u, some p =>
      let state ← stateRef.get
      match state.users.get? u with
      | none => return jsonError 401 "Invalid credentials"
      | some user =>
        if user.password != p then
          return jsonError 401 "Invalid credentials"
        
        let rand ← IO.rand 1000000000 9999999999
        let token := toString user.id ++ "-" ++ toString rand
        
        stateRef.modify fun s => {
          s with
          sessions := s.sessions.insert token user.id
        }
        
        let resp := jsonSuccess 200 (userToJson user)
        return {
          resp with
          headers := resp.headers.push ("Set-Cookie", "session_id=" ++ token ++ "; Path=/; HttpOnly")
        }

  let handleLogout : Handler := fun req => do
    match ← requireAuth req with
    | none => return jsonError 401 "Authentication required"
    | some _ =>
      let header := req.headers.find? (fun (k, _) => k.toLower == "cookie")
      let cookieStr := header.map (fun (_, v) => v)
      let tokenOpt := cookieStr >>= fun c => 
        let parts := c.splitOn ";"
        parts.find? (fun p => p.trimAscii.toString.startsWith "session_id=") |>.map (fun p => p.trimAscii.drop 11 |>.toString)
      match tokenOpt with
      | some token =>
        stateRef.modify fun s => { s with sessions := s.sessions.erase token }
      | none => pure ()
      return jsonSuccess 200 "{}"

  let handleMe : Handler := fun req => do
    match ← requireAuth req with
    | none => return jsonError 401 "Authentication required"
    | some userId =>
      let state ← stateRef.get
      match state.users.toArray.find? (fun (_, u) => u.id == userId) with
      | none => return jsonError 401 "Authentication required"
      | some (_, user) =>
        return jsonSuccess 200 (userToJson user)

  let handlePutPassword : Handler := fun req => do
    match ← requireAuth req with
    | none => return jsonError 401 "Authentication required"
    | some userId =>
      let reqStr := String.fromUTF8! req.body
      let op := extractStr reqStr "old_password"
      let np := extractStr reqStr "new_password"
      match op, np with
      | none, _ | _, none => return jsonError 400 "Invalid request"
      | some o, some n =>
        if n.length < 8 then
          return jsonError 400 "Password too short"
        
        let state ← stateRef.get
        match state.users.toArray.find? (fun (_, u) => u.id == userId) with
        | none => return jsonError 401 "Invalid credentials"
        | some (uname, user) =>
          if user.password != o then
            return jsonError 401 "Invalid credentials"
          
          let newUser := { user with password := n }
          stateRef.modify fun s => { s with users := s.users.insert uname newUser }
          return jsonSuccess 200 "{}"

  let handleGetTodos : Handler := fun req => do
    match ← requireAuth req with
    | none => return jsonError 401 "Authentication required"
    | some userId =>
      let state ← stateRef.get
      let userTodos := state.todos.toArray.filter (fun (_, t) => t.userId == userId) |>.map (fun (_, t) => t)
      let sortedTodos := userTodos.qsort (fun a b => a.id < b.id)
      let todosArray : Array String := sortedTodos.map todoToJson
      let mut todosStr := "["
      for i in [:todosArray.size] do
        if i > 0 then todosStr := todosStr ++ ", "
        todosStr := todosStr ++ todosArray[i]!
      todosStr := todosStr ++ "]"
      return jsonSuccess 200 todosStr

  let handlePostTodos : Handler := fun req => do
    match ← requireAuth req with
    | none => return jsonError 401 "Authentication required"
    | some userId =>
      let reqStr := String.fromUTF8! req.body
      let title := extractStr reqStr "title"
      match title with
      | none => return jsonError 400 "Title is required"
      | some t =>
        if isBlank t then
          return jsonError 400 "Title is required"
        
        let desc := extractStr reqStr "description"
        let descStr := match desc with | some d => d | none => ""
        let ts ← getTimestamp
        let state ← stateRef.get
        let newTodo : Todo := {
          id := state.nextTodoId
          userId := userId
          title := t
          description := descStr
          completed := false
          createdAt := ts
          updatedAt := ts
        }
        stateRef.modify fun s => {
          s with
          nextTodoId := s.nextTodoId + 1
          todos := s.todos.insert newTodo.id newTodo
        }
        return jsonSuccess 201 (todoToJson newTodo)

  let handleGetTodo : Handler := fun req => do
    match ← requireAuth req with
    | none => return jsonError 401 "Authentication required"
    | some userId =>
      let idStr := match req.params.get? "id" with | some s => s | none => ""
      match idStr.toNat? with
      | none => return jsonError 404 "Todo not found"
      | some id =>
        let state ← stateRef.get
        match state.todos.get? id with
        | none => return jsonError 404 "Todo not found"
        | some todo =>
          if todo.userId != userId then
            return jsonError 404 "Todo not found"
          return jsonSuccess 200 (todoToJson todo)

  let handlePutTodo : Handler := fun req => do
    match ← requireAuth req with
    | none => return jsonError 401 "Authentication required"
    | some userId =>
      let idStr := match req.params.get? "id" with | some s => s | none => ""
      match idStr.toNat? with
      | none => return jsonError 404 "Todo not found"
      | some id =>
        let state ← stateRef.get
        match state.todos.get? id with
        | none => return jsonError 404 "Todo not found"
        | some todo =>
          if todo.userId != userId then
            return jsonError 404 "Todo not found"
          
          let reqStr := String.fromUTF8! req.body
          let titleOpt := extractStr reqStr "title"
          if titleOpt.isSome && isBlank (match titleOpt with | some t => t | none => "") then
            return jsonError 400 "Title is required"
          
          let descOpt := extractStr reqStr "description"
          let completedOpt := extractBool reqStr "completed"
          let ts ← getTimestamp
          
          let newTitle := match titleOpt with | some t => t | none => todo.title
          let newDesc := match descOpt with | some d => d | none => todo.description
          let newCompleted := match completedOpt with | some b => b | none => todo.completed
          
          let updatedTodo := {
            todo with
            title := newTitle
            description := newDesc
            completed := newCompleted
            updatedAt := ts
          }
          stateRef.modify fun s => { s with todos := s.todos.insert id updatedTodo }
          return jsonSuccess 200 (todoToJson updatedTodo)

  let handleDeleteTodo : Handler := fun req => do
    match ← requireAuth req with
    | none => return jsonError 401 "Authentication required"
    | some userId =>
      let idStr := match req.params.get? "id" with | some s => s | none => ""
      match idStr.toNat? with
      | none => return jsonError 404 "Todo not found"
      | some id =>
        let state ← stateRef.get
        match state.todos.get? id with
        | none => return jsonError 404 "Todo not found"
        | some todo =>
          if todo.userId != userId then
            return jsonError 404 "Todo not found"
          
          stateRef.modify fun s => { s with todos := s.todos.erase id }
          return jsonSuccessNoBody 204

  let router ← Router.new
  router.post "/register" handleRegister
  router.post "/login" handleLogin
  router.post "/logout" handleLogout
  router.get "/me" handleMe
  router.put "/password" handlePutPassword
  router.get "/todos" handleGetTodos
  router.post "/todos" handlePostTodos
  router.get "/todos/{id}" handleGetTodo
  router.put "/todos/{id}" handlePutTodo
  router.delete "/todos/{id}" handleDeleteTodo
  return router

def main (args : List String) : IO Unit := do
  let mut port : UInt16 := 3000
  let mut remaining := args
  while remaining.length > 0 do
    match remaining with
    | "--port" :: p :: rest =>
      match p.toNat? with
      | some p' => port := UInt16.ofNat p'
      | none => pure ()
      remaining := rest
    | arg :: rest =>
      if arg.startsWith "--port=" then
        let pStr := arg.drop 7
        match pStr.toNat? with
        | some p' => port := UInt16.ofNat p'
        | none => pure ()
      remaining := rest
    | [] => pure ()

  let initialState : AppState := {
    nextUserId := 1
    nextTodoId := 1
    users := {}
    sessions := {}
    todos := {}
  }
  let stateRef ← IO.mkRef initialState
  let router ← makeHandlers stateRef
  IO.println ("Starting server on port " ++ toString port)
  router.listen port
