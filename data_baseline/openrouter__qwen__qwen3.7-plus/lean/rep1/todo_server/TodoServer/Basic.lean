import LeanHTTP
import Lean.Data.Json
import Std.Time
import Std.Time.Format
import Std.Data.HashMap

namespace TodoServer

open Std.Time
open LeanHTTP
open Lean.Json

-- State Management
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

-- Application State
structure AppState where
  nextUserId : Nat
  nextTodoId : Nat
  users : Std.HashMap String User
  sessions : Std.HashMap String Nat
  todos : Std.HashMap Nat Todo

def initialState : AppState :=
  let u : Std.HashMap String User := ∅
  let s : Std.HashMap String Nat := ∅
  let t : Std.HashMap Nat Todo := ∅
  { nextUserId := 1
  , nextTodoId := 1
  , users := u
  , sessions := s
  , todos := t
  }

-- Helpers
def getIso8601Timestamp : IO String := do
  let now ← Timestamp.now
  let dt := ZonedDateTime.ofTimestampWithZone now TimeZone.UTC
  pure (Formats.iso8601.format (ZonedDateTime.toDateTime dt))

def genUuid : IO String := do
  let mut res := ""
  let mut seed : UInt64 := UInt64.ofNat (← IO.monoNanosNow)
  for i in [0:36] do
    if i == 8 || i == 13 || i == 18 || i == 23 then
      res := res ++ "-"
    else if i == 14 then
      res := res ++ "4"
    else
      seed := (seed * 1103515245 + 12345)
      let charIdx := (seed % 16).toNat
      let chars := #['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f']
      res := res ++ String.push "" chars[charIdx]!
  pure res

def jsonEscape (s : String) : String :=
  s.foldl (fun acc c =>
    if c == '"' then acc ++ "\\\""
    else if c == '\\' then acc ++ "\\\\"
    else if c == '\n' then acc ++ "\\n"
    else if c == '\r' then acc ++ "\\r"
    else if c == '\t' then acc ++ "\\t"
    else acc.push c
  ) ""

def mkUserJson (u : User) : String :=
  "{\"id\": " ++ toString u.id ++ ", \"username\": \"" ++ jsonEscape u.username ++ "\"}"

def mkTodoJson (t : Todo) : String :=
  "{\"id\": " ++ toString t.id ++ ", \"title\": \"" ++ jsonEscape t.title ++ 
  "\", \"description\": \"" ++ jsonEscape t.description ++ 
  "\", \"completed\": " ++ toString t.completed ++ 
  ", \"created_at\": \"" ++ t.createdAt ++ 
  "\", \"updated_at\": \"" ++ t.updatedAt ++ "\"}"

def mkErrorJson (err : String) : String :=
  "{\"error\": \"" ++ jsonEscape err ++ "\"}"

def mkEmptyJson : String := "{}"

def mkArrayJson (items : List String) : String :=
  "[" ++ String.intercalate ", " items ++ "]"

-- JSON Helpers
def getStringField (j : Json) (key : String) : Option String :=
  match j with
  | obj kv => 
    match kv.get? key with
    | some (str s) => some s
    | _ => none
  | _ => none

def getBoolField (j : Json) (key : String) : Option Bool :=
  match j with
  | obj kv => 
    match kv.get? key with
    | some (bool v) => some v
    | _ => none
  | _ => none

def parseJsonBody (req : HttpRequest) : Option Json :=
  let str := String.fromUTF8! req.body
  match Json.parse str with
  | .ok j => some j
  | _ => none

-- Helpers for validation
def isValidUsername (username : String) : Bool :=
  let len := username.length
  3 ≤ len ∧ len ≤ 50 ∧ username.all (fun c => c.isAlphanum || c == '_')

def isValidPassword (password : String) : Bool :=
  password.length ≥ 8

def isValidTitle (title : String) : Bool :=
  !title.isEmpty

-- Handlers factory
def makeApp (stateRef : IO.Ref AppState) : IO Router := do
  let r ← Router.new

  -- POST /register
  r.post "/register" (fun req => do
    match parseJsonBody req with
    | some j =>
      match getStringField j "username", getStringField j "password" with
      | some username, some password =>
        if !(isValidUsername username) then
          pure (HttpResponse.json 400 (mkErrorJson "Invalid username"))
        else if !(isValidPassword password) then
          pure (HttpResponse.json 400 (mkErrorJson "Password too short"))
        else
          let state ← stateRef.get
          if state.users.contains username then
            pure (HttpResponse.json 409 (mkErrorJson "Username already exists"))
          else
            let newUser : User := { 
              id := state.nextUserId, 
              username := username, 
              password := password 
            }
            let newUsers := state.users.insert username newUser
            let newState := { 
              state with 
              users := newUsers, 
              nextUserId := state.nextUserId + 1 
            }
            stateRef.set newState
            pure (HttpResponse.json 201 (mkUserJson newUser))
      | _, _ => pure (HttpResponse.json 400 (mkErrorJson "Missing username or password"))
    | none => pure (HttpResponse.json 400 (mkErrorJson "Invalid JSON"))
  )

  -- POST /login
  r.post "/login" (fun req => do
    match parseJsonBody req with
    | some j =>
      match getStringField j "username", getStringField j "password" with
      | some username, some password =>
        let state ← stateRef.get
        match state.users[username]? with
        | some user =>
          if user.password == password then
            let sessionId ← genUuid
            let newSessions := state.sessions.insert sessionId user.id
            let newState := { state with sessions := newSessions }
            stateRef.set newState
            
            let resp := HttpResponse.json 200 (mkUserJson user)
            let opts : CookieOptions := { path := some "/", httpOnly := true }
            pure (resp.setCookie "session_id" sessionId opts)
          else
            pure (HttpResponse.json 401 (mkErrorJson "Invalid credentials"))
        | none => pure (HttpResponse.json 401 (mkErrorJson "Invalid credentials"))
      | _, _ => pure (HttpResponse.json 400 (mkErrorJson "Missing username or password"))
    | none => pure (HttpResponse.json 400 (mkErrorJson "Invalid JSON"))
  )

  -- Helper for auth check
  let requireAuth (req : HttpRequest) (handler : Nat → IO HttpResponse) : IO HttpResponse := do
    match req.cookie "session_id" with
    | some sessionId =>
      let state ← stateRef.get
      match state.sessions[sessionId]? with
      | some userId => handler userId
      | none => pure (HttpResponse.json 401 (mkErrorJson "Authentication required"))
    | none => pure (HttpResponse.json 401 (mkErrorJson "Authentication required"))

  -- POST /logout
  r.post "/logout" (fun req => do
    requireAuth req (fun userId => do
      match req.cookie "session_id" with
      | some sessionId =>
        let state ← stateRef.get
        let newSessions := state.sessions.erase sessionId
        stateRef.set { state with sessions := newSessions }
        pure (HttpResponse.json 200 mkEmptyJson)
      | none => pure (HttpResponse.json 401 (mkErrorJson "Authentication required"))
    )
  )

  -- GET /me
  r.get "/me" (fun req => do
    requireAuth req (fun userId => do
      let state ← stateRef.get
      let userOpt := state.users.fold (fun (acc : Option User) (k : String) (u : User) => 
        if u.id == userId then some u else acc
      ) none
      match userOpt with
      | some user => pure (HttpResponse.json 200 (mkUserJson user))
      | none => pure (HttpResponse.json 401 (mkErrorJson "Authentication required"))
    )
  )

  -- PUT /password
  r.put "/password" (fun req => do
    requireAuth req (fun userId => do
      let state ← stateRef.get
      let userOpt := state.users.fold (fun (acc : Option User) (k : String) (u : User) => 
        if u.id == userId then some u else acc
      ) none
      match userOpt with
      | some user =>
        match parseJsonBody req with
        | some j =>
          match getStringField j "old_password", getStringField j "new_password" with
          | some oldPass, some newPass =>
            if user.password != oldPass then
              pure (HttpResponse.json 401 (mkErrorJson "Invalid credentials"))
            else if !(isValidPassword newPass) then
              pure (HttpResponse.json 400 (mkErrorJson "Password too short"))
            else
              let newUser := { user with password := newPass }
              let newUsers := state.users.insert user.username newUser
              stateRef.set { state with users := newUsers }
              pure (HttpResponse.json 200 mkEmptyJson)
          | _, _ => pure (HttpResponse.json 400 (mkErrorJson "Missing old_password or new_password"))
        | none => pure (HttpResponse.json 400 (mkErrorJson "Invalid JSON"))
      | none => pure (HttpResponse.json 401 (mkErrorJson "Authentication required"))
    )
  )

  -- GET /todos
  r.get "/todos" (fun req => do
    requireAuth req (fun userId => do
      let state ← stateRef.get
      let userTodos := state.todos.fold (fun (acc : Array Todo) (k : Nat) (t : Todo) => 
        if t.userId == userId then acc.push t else acc
      ) #[]
      let sorted := userTodos.qsort (fun a b => a.id < b.id)
      let jsonList := sorted.toList.map mkTodoJson
      pure (HttpResponse.json 200 (mkArrayJson jsonList))
    )
  )

  -- POST /todos
  r.post "/todos" (fun req => do
    requireAuth req (fun userId => do
      match parseJsonBody req with
      | some j =>
        let titleOpt := getStringField j "title"
        let descOpt := getStringField j "description"
        
        let title := match titleOpt with
          | some t => t
          | none => ""
        
        if !(isValidTitle title) then
          pure (HttpResponse.json 400 (mkErrorJson "Title is required"))
        else
          let description := match descOpt with
            | some d => d
            | none => ""
          
          let state ← stateRef.get
          let now ← getIso8601Timestamp
          let newTodo : Todo := {
            id := state.nextTodoId,
            userId := userId,
            title := title,
            description := description,
            completed := false,
            createdAt := now,
            updatedAt := now
          }
          let newTodos := state.todos.insert newTodo.id newTodo
          let newState := { state with todos := newTodos, nextTodoId := state.nextTodoId + 1 }
          stateRef.set newState
          
          pure (HttpResponse.json 201 (mkTodoJson newTodo))
      | none => pure (HttpResponse.json 400 (mkErrorJson "Invalid JSON"))
    )
  )

  -- GET /todos/:id
  r.get "/todos/{id}" (fun req => do
    requireAuth req (fun userId => do
      match req.paramNat "id" with
      | some todoId =>
        let state ← stateRef.get
        match state.todos[todoId]? with
        | some todo =>
          if todo.userId == userId then
            pure (HttpResponse.json 200 (mkTodoJson todo))
          else
            pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
        | none => pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
      | none => pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
    )
  )

  -- PUT /todos/:id
  r.put "/todos/{id}" (fun req => do
    requireAuth req (fun userId => do
      match req.paramNat "id" with
      | some todoId =>
        let state ← stateRef.get
        match state.todos[todoId]? with
        | some todo =>
          if todo.userId == userId then
            match parseJsonBody req with
            | some j =>
              let titleOpt := getStringField j "title"
              let descOpt := getStringField j "description"
              let completedOpt := getBoolField j "completed"
              
              let newTitle : String := Id.run do
                match titleOpt with
                | some t => 
                  if !(isValidTitle t) then return HttpResponse.json 400 (mkErrorJson "Title is required")
                  else pure t
                | none => pure todo.title
              
              let newDesc := match descOpt with
                | some d => d
                | none => todo.description
              
              let newCompleted : Bool := match completedOpt with
                | some b => b
                | none => todo.completed
              
              let now ← getIso8601Timestamp
              let updatedTodo := { 
                todo with 
                title := newTitle, 
                description := newDesc, 
                completed := newCompleted, 
                updatedAt := now 
              }
              
              let newTodos := state.todos.insert todoId updatedTodo
              stateRef.set { state with todos := newTodos }
              
              pure (HttpResponse.json 200 (mkTodoJson updatedTodo))
            | none => pure (HttpResponse.json 400 (mkErrorJson "Invalid JSON"))
          else
            pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
        | none => pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
      | none => pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
    )
  )

  -- DELETE /todos/:id
  r.delete "/todos/{id}" (fun req => do
    requireAuth req (fun userId => do
      match req.paramNat "id" with
      | some todoId =>
        let state ← stateRef.get
        match state.todos[todoId]? with
        | some todo =>
          if todo.userId == userId then
            let newTodos := state.todos.erase todoId
            stateRef.set { state with todos := newTodos }
            pure HttpResponse.noContent
          else
            pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
        | none => pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
      | none => pure (HttpResponse.json 404 (mkErrorJson "Todo not found"))
    )
  )

  pure r

end TodoServer