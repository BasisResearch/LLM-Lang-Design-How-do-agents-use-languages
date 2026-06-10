-- Basic HTTP server functionality with all business logic
import Init.Data.ToString.Macro
import Init.Data.ToString.Basic
import Std.Data.HashMap

open Std (HashMap)

/-- HTTP methods --/
inductive Method 
  | get | post | put | delete
deriving Repr, BEq

/-- Request structure --/
structure Request where
  method : Method 
  path : String
  body : String
  headers : Array (String × String)
deriving Repr

/-- Response status codes --/
inductive StatusCodes
  | ok         -- 200
  | created    -- 201
  | noContent  -- 204
  | badRequest -- 400
  | unauthorized -- 401
  | notFound   -- 404
  | conflict   -- 409
deriving Repr, BEq

/-- Response structure --/
structure Response where
  status : StatusCodes
  headers : Array (String × String)
  body : String
deriving Repr

/-- User data type -/
structure User where
  id : UInt32
  username : String
  password : String
deriving Repr, Inhabited

/-- Todo data type -/
structure Todo where
  id : UInt32
  userId : UInt32
  title : String
  description : String
  completed : Bool
  createdAt : String
  updatedAt : String
deriving Repr

/-- Main server context -/
abbrev Context := {
  users : HashMap String User,
  todos : HashMap UInt32 Todo,
  sessions : HashMap String UInt32, -- session_id -> user_id
  nextUserId : UInt32,
  nextTodoId : UInt32
}

/-- Global server state -/
initialize gContext : IO.Ref Context ← IO.mkRef { 
  users := {},
  todos := {},
  sessions := {},
  nextUserId := 1,
  nextTodoId := 1
}

/-- Helper to get current timestamp -/
def getCurrentTimeStr : IO String := do
  let ms ← IO.monoMsNow
  let sec := ms / 1000
  let year := 2023
  let month := 1
  let day := (360 + (sec / 86400)) % 30 + 1
  let hour := (sec / 3600) % 24
  let min := (sec / 60) % 60
  let secOfDay := sec % 60
  return s!"{year}-{:02d}-{:02d}T{:02d}:{:02d}:{:02d}Z".format (month, day, hour, min, secOfDay)

/-- Format helper -/
private def Format.format_uint32 (n : UInt32) (fill : Nat) (base : Nat := 10) : String :=
  let s := toString n
  let pad := fill - min s.length fill
  ("".pushn '0' pad) ++ s

def StatusCodes.toString : StatusCodes → String
  | .ok => "200 OK"
  | .created => "201 Created"
  | .noContent => "204 No Content"
  | .badRequest => "400 Bad Request"
  | .unauthorized => "401 Unauthorized"
  | .notFound => "404 Not Found"
  | .conflict => "409 Conflict"

/-- Check if username is valid (alphanumeric and underscore only, 3-50 chars) -/
def isUsernameValid (username : String) : Bool := 
  let len := username.length
  if len < 3 || len > 50 then false
  else
    username.all fun c => c.isAlphanum || c == '_'

/-- Check if password is valid (at least 8 characters) -/
def isPasswordValid (password : String) : Bool := 
  password.length >= 8

/-- Generate a random session ID -/
def generateSessionId : IO String := do
  let timestamp ← IO.monoMsNow
  return s!"session_{timestamp}"

/-- Get user by session ID -/
def getUserBySession (sessionId : String) : IO (Option User) := do
  let ctx ← gContext.get
  match ctx.sessions.find? sessionId with
  | some userId => 
    for (username, user) in ctx.users.toArray do
      if user.id == userId then
        return some user
    return none
  | none => return none

/-- Parse JSON to extract specific field value - simplified -/
def parseJsonField (jsonStr : String) (field : String) : Option String := Id.run do
  let searchFor := "\"" ++ field ++ "\":"  
  let pos := jsonStr.toLower.indexOf searchFor.toLower
  if pos == String.pos.uint8.max then
    return none
  else 
    let afterField := jsonStr.drop (pos + searchFor.length)
    let afterColonWs := afterField.dropWhile (fun c => c == ' ' || c == ':')
    
    if afterColonWs.front? == some '"' then
      -- String value
      let valueStart := afterColonWs.extractFrom 1 (afterColonWs.length - 1)
      let endIndex := valueStart.indexOf '"'
      if endIndex != String.pos.uint8.max then
        return some (String.take valueStart endIndex)
      else return none
    else
      -- Literal value (like boolean or number)
      let parts := afterColonWs.splitOn (fun c => c == ',' || c == '}' || c == ']')
      if parts.isEmpty then return none
      else
        let cleanPart := parts[0]!.trim
        return some cleanPart

namespace String
  def extractFrom (s : String) (startIdx : Nat) (endIdx : Nat) : String := 
    if startIdx ≥ s.length then "" 
    else if startIdx ≥ endIdx then ""
    else String.drop s startIdx |>.take (endIdx - startIdx)
end String

/-- Handle registration POST -/
def handleRegister (body : String) : IO Response := do
  let username := parseJsonField body "username".getD ""
  let password := parseJsonField body "password".getD ""

  if !isUsernameValid username then
    return { status := .badRequest, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid username\"}" }
  
  if !isPasswordValid password then
    return { status := .badRequest, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Password too short\"}" }
  
  let ctx ← gContext.get
  if ctx.users.contains username then
    return { status := .conflict, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Username already exists\"}" }
  
  let newUser := { id := ctx.nextUserId, username := username, password := password }
  let newCtx := {
    ctx with 
      users := ctx.users.insert username newUser,
      nextUserId := ctx.nextUserId + 1
  }
  gContext.set newCtx
  
  let response := s!"{{\"id\": {newUser.id}, \"username\": \"{escapeJsonString newUser.username}\"}}"
  return { status := .created, headers := #[("Content-Type", "application/json")], body := response }

/-- Escape special characters for JSON output -/
def escapeJsonString (str : String) : String :=
  str.replace "\"" "\\\"".replace "\\" "\\\\".replace "\n" "\\n".replace "\r" "\\r".replace "\t" "\\t"

/-- Handle login POST -/
def handleLogin (body : String) : IO Response := do
  let username := parseJsonField body "username".getD ""
  let password := parseJsonField body "password".getD ""
    
  let ctx ← gContext.get
  let user? := ctx.users.find? username
  
  match user? with
  | some user =>
    if user.password == password then
      let sessionId ← generateSessionId
      let newCtx := {
        ctx with 
          sessions := ctx.sessions.insert sessionId user.id
      }
      gContext.set newCtx
      
      let response := s!"{{\"id\": {user.id}, \"username\": \"{escapeJsonString user.username}\"}}"
      return { 
        status := .ok, 
        headers := #[("Content-Type", "application/json"), ("Set-Cookie", s!"session_id={sessionId}; Path=/; HttpOnly")], 
        body := response 
      }
    else
      return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid credentials\"}" }
  | none =>
    return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid credentials\"}" }

/-- Handle logout POST -/
def handleLogout (req : Request) : IO Response := do
  let cookies := req.headers.find? (fun (k, _) => k.toLower == "cookie").getD ("", "")
  let (_, cookieValue) := cookies
  let sessionId := if cookieValue == "" then none else 
    let cookiePairs := cookieValue.splitOn ";"
    let sessionIdPair? := cookiePairs.find? (fun pair => pair.toLower.trim.startsWith "session_id=".toLower)
    match sessionIdPair? with
    | some pair => 
      let rawValue := pair.extractAfterEq.trim
      some rawValue
    | none => none
  
  match sessionId with
  | some id => 
    let ctx ← gContext.get
    if ctx.sessions.contains id then
      let newSessions := ctx.sessions.erase id
      let newCtx := { ctx with sessions := newSessions }
      gContext.set newCtx
      return { status := .ok, headers := #[("Content-Type", "application/json")], body := "{}" }
    else
      return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Authentication required\"}" }
  | none =>
    return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Authentication required\"}" }

/-- Extract value after equals sign -/
def String.extractAfterEq (str : String) : String := 
  let items := str.splitOn "="
  if items.size <= 1 then "" else items[1]!

/-- Get user associated with a request by session cookie -/
def getUserFromRequest (req : Request) : IO (Option User) := do
  let cookies := req.headers.find? (fun (k, _) => k.toLower == "cookie").getD ("", "")
  let (_, cookieValue) := cookies
  let sessionId := if cookieValue == "" then none else 
    let cookiePairs := cookieValue.splitOn ";"
    for pair in cookiePairs do
      let trimmedPair := pair.trim
      if trimmedPair.toLower.startsWith "session_id=" then
        let value := trimmedPair.extractAfterEq.trim
        return some value
    none
  
  match sessionId with
  | some id => getUserBySession id
  | none => return none

/-- Handle get user info (/me) -/
def handleMe (req : Request) : IO Response := do
  let user? ← getUserFromRequest req
  match user? with
  | some user => 
    let response := s!"{{\"id\": {user.id}, \"username\": \"{escapeJsonString user.username}\"}}"
    return { status := .ok, headers := #[("Content-Type", "application/json")], body := response }
  | none =>
    return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Authentication required\"}" }

/-- Handle password change -/
def handlePasswordChange (req : Request) (body : String) : IO Response := do
  let user? ← getUserFromRequest req
  match user? with
  | none => 
    return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Authentication required\"}" }
  | some currentUser =>
    let oldPassword := parseJsonField body "old_password".getD ""
    let newPassword := parseJsonField body "new_password".getD ""
    
    if currentUser.password != oldPassword then
      return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid credentials\"}" }
    
    if !isPasswordValid newPassword then
      return { status := .badRequest, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Password too short\"}" }
    
    let ctx ← gContext.get
    let newUsers := ctx.users.insert currentUser.username { currentUser with password := newPassword }
    gContext.set { ctx with users := newUsers }
    return { status := .ok, headers := #[("Content-Type", "application/json")], body := "{}" }

/-- Handle getting todos -/
def handleGetTodos (req : Request) : IO Response := do
  let user? ← getUserFromRequest req
  match user? with
  | none => 
    return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Authentication required\"}" }
  | some user =>
    let ctx ← gContext.get
    let userTodos : Array (UInt32 × Todo) := 
      ctx.todos.toArray.filter fun (k, v) => v.userId == user.id
    
    -- Sort todos by id ascending
    let sortedTodos := userTodos.qsort (fun a b => a.2.id < b.2.id)
    let todoArray : Array String := sortedTodos.map fun (_, todo) => 
      s!"{{\"id\": {todo.id}, \"title\": \"{escapeJsonString todo.title}\", \"description\": \"{escapeJsonString todo.description}\", \"completed\": {if todo.completed then "true" else "false"}, \"created_at\": \"{todo.createdAt}\", \"updated_at\": \"{todo.updatedAt}\"}}"
    
    let response := "[" ++ (String.intercalate "," todoArray) ++ "]"
    return { status := .ok, headers := #[("Content-Type", "application/json")], body := response }

/-- Handle creating a todo -/
def handleCreateTodo (req : Request) (body : String) : IO Response := do
  let user? ← getUserFromRequest req
  match user? with
  | none => 
    return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Authentication required\"}" }
  | some user =>
    let title := parseJsonField body "title".getD ""
    let description := parseJsonField body "description".getD ""
    
    if title.isEmpty then
      return { status := .badRequest, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Title is required\"}" }
    
    let ctx ← gContext.get
    let timestamp ← getCurrentTimeStr
    let newTodo := {
      id := ctx.nextTodoId,
      userId := user.id,
      title := title,
      description := description,
      completed := false,
      createdAt := timestamp,
      updatedAt := timestamp
    }
    
    let newCtx := {
      ctx with
        todos := ctx.todos.insert ctx.nextTodoId newTodo,
        nextTodoId := ctx.nextTodoId + 1
    }
    gContext.set newCtx
    
    let response := s!"{{\"id\": {newTodo.id}, \"title\": \"{escapeJsonString newTodo.title}\", \"description\": \"{escapeJsonString newTodo.description}\", \"completed\": false, \"created_at\": \"{newTodo.createdAt}\", \"updated_at\": \"{newTodo.updatedAt}\"}}"
    return { status := .created, headers := #[("Content-Type", "application/json")], body := response }

/-- Find a todo by ID and current user -/
def findTodoForUser (req : Request) (todoIdStr : String) : IO (Option Todo) := do
  let todoId? := String.toUInt32? todoIdStr
  match todoId? with
  | none => return none
  | some todoId =>
    let user? ← getUserFromRequest req
    match user? with
    | none => return none
    | some user =>
      let ctx ← gContext.get
      match ctx.todos.find? todoId with
      | some todo => 
        if todo.userId == user.id then
          some todo
        else
          none
      | none => 
        none

/-- Handle getting a specific todo -/
def handleGetTodoById (req : Request) (todoIdStr : String) : IO Response := do
  let todo? ← findTodoForUser req todoIdStr
  match todo? with
  | some todo =>
    let response := s!"{{\"id\": {todo.id}, \"title\": \"{escapeJsonString todo.title}\", \"description\": \"{escapeJsonString todo.description}\", \"completed\": {if todo.completed then "true" else "false"}, \"created_at\": \"{todo.createdAt}\", \"updated_at\": \"{todo.updatedAt}\"}}"
    return { status := .ok, headers := #[("Content-Type", "application/json")], body := response }
  | none =>
    return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Todo not found\"}" }

/-- Update a specific todo by id (partial update) -/
def handleUpdateTodo (req : Request) (todoIdStr : String) (body : String) : IO Response := do
  let todoId? := String.toUInt32? todoIdStr
  match todoId? with
  | none => 
    return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Todo not found\"}" }
  | some todoId =>
    let user? ← getUserFromRequest req
    match user? with
    | none => 
      return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Authentication required\"}" }
    | some user =>
      let ctx ← gContext.get
      match ctx.todos.find? todoId with
      | none => 
        return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Todo not found\"}" }
      | some origTodo =>
        if origTodo.userId != user.id then
          return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Todo not found\"}" }
        
        -- Parse update fields from body
        let titleOpt := parseJsonField body "title"
        let descriptionOpt := parseJsonField body "description"
        let completedOpt := parseJsonField body "completed"
        
        -- Validate if title is provided but empty
        match titleOpt with
        | some t =>
          if t.isEmpty then
            return { status := .badRequest, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Title is required\"}" }
        | none => ()
        
        -- Apply updates 
        let updatedTitle := titleOpt.getD origTodo.title
        let updatedDescription := descriptionOpt.getD origTodo.description
        let updatedCompleted := 
          match completedOpt with
          | some "true" => true
          | some "false" => false
          | _ => origTodo.completed
        
        let timestamp ← getCurrentTimeStr
        let updatedTodo := {
          origTodo with
          title := updatedTitle,
          description := updatedDescription,
          completed := updatedCompleted,
          updatedAt := timestamp
        }
        
        let newTodos := ctx.todos.insert todoId updatedTodo
        gContext.set { ctx with todos := newTodos }
        
        let response := s!"{{\"id\": {updatedTodo.id}, \"title\": \"{escapeJsonString updatedTodo.title}\", \"description\": \"{escapeJsonString updatedTodo.description}\", \"completed\": {if updatedTodo.completed then "true" else "false"}, \"created_at\": \"{updatedTodo.createdAt}\", \"updated_at\": \"{updatedTodo.updatedAt}\"}}"
        return { status := .ok, headers := #[("Content-Type", "application/json")], body := response }

/-- Delete a specific todo -/
def handleDeleteTodo (req : Request) (todoIdStr : String) : IO Response := do
  let todoId? := String.toUInt32? todoIdStr
  match todoId? with
  | none => 
    return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Todo not found\"}" }
  | some todoId =>
    let user? ← getUserFromRequest req
    match user? with
    | none => 
      return { status := .unauthorized, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Authentication required\"}" }
    | some user =>
      let ctx ← gContext.get
      match ctx.todos.find? todoId with
      | none => 
        return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Todo not found\"}" }
      | some todo =>
        if todo.userId != user.id then
          return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Todo not found\"}" }        
        -- Remove the todo
        let newTodos := ctx.todos.erase todoId
        gContext.set { ctx with todos := newTodos }
        
        return { status := .noContent, headers := #[], body := "" }

/-- Main request handler -/
def requestHandler (req : Request) : IO Response := do
  -- Route requests based on method and path
  if req.method == .post && req.path == "/register" then
    handleRegister req.body
  else if req.method == .post && req.path == "/login" then
    handleLogin req.body
  else if req.method == .post && req.path == "/logout" then
    handleLogout req
  else if req.method == .get && req.path == "/me" then
    handleMe req
  else if req.method == .put && req.path == "/password" then
    handlePasswordChange req req.body
  else if req.method == .get && req.path == "/todos" then
    handleGetTodos req
  else if req.method == .post && req.path == "/todos" then
    handleCreateTodo req req.body
  else if req.method == .get && req.path.startsWith "/todos/" then
    let todoId := req.path.extractTodoId
    match todoId with
    | some id => handleGetTodoById req id
    | none => return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid route\"}" }
  else if req.method == .put && req.path.startsWith "/todos/" then
    let todoId := req.path.extractTodoId
    match todoId with
    | some id => handleUpdateTodo req id req.body
    | none => return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid route\"}" }
  else if req.method == .delete && req.path.startsWith "/todos/" then
    let todoId := req.path.extractTodoId
    match todoId with
    | some id => handleDeleteTodo req id
    | none => return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid route\"}" }
  else
    -- Default: not found
    return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Route not found\"}" }

/-- Helper to extract todo ID from path like /todos/123 -/
def String.extractTodoId (path : String) : Option String := 
  let prefix := "/todos/"
  if path.startsWith prefix then
    let remainingPath := String.drop path prefix.length
    let segments : Array String := remainingPath.splitOn "/"
    if segments.isEmpty || segments[0]!.isEmpty then none 
    else 
      let idSegment := segments[0]!
      -- Confirm that this segment contains digits only
      if idSegment.all (·.isDigit) then
        some idSegment
      else none
  else
    none

/-- Parse command line arguments to extract port -/
def parsePortFromArgs : IO UInt32 := do
  let args ← IO.getArgs
  var port : UInt32 := 8080
  
  for i in [0:args.size] do
    let arg := args[i]!
    if arg == "--port" && i + 1 < args.size then
      match String.toUInt32? (args[i + 1]!) with
      | some p => port := p
      | none => IO.eprintln s!"Warning: Invalid port: {args[i + 1]!}"

  return port

/-- Mock server launch function --/
def serve (config: {host : String, port : UInt32, handler : Request → IO Response}) : IO Unit := do
  IO.println s!"[Mock Server] Starting on {config.host}:{config.port}"
  IO.println "[Mock Server] Ready for integration with real HTTP server when dependency is resolved"

def main : IO Unit := do
  let port ← parsePortFromArgs
  let server := { host := "0.0.0.0", port := port, handler := requestHandler }
  IO.println s!"Server starting on {server.host}:{server.port}"
  serve server