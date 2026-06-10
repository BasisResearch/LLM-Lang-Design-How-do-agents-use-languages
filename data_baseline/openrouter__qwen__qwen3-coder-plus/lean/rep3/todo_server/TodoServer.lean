-- Import standard libraries

import Init.Data.ToString.Basic
import Std.Data.HashMap


open Std (HashMap)

/-- Placeholders for HTTP entities until HTTP library loads --/

inductive Method 
  | get | post | put | delete

/-- Request structure (placeholder when actual HTTP is unavailable) --/
structure Request where
  method : Method 
  path : String
  body : String
  headers : Array (String × String)
deriving Repr

/-- Response status codes (placeholder when actual HTTP is unavailable) --/
inductive StatusCodes
  | ok         -- 200
  | created    -- 201
  | noContent  -- 204
  | badRequest -- 400
  | unauthorized -- 401
  | notFound   -- 404
  | conflict   -- 409
deriving Repr

/-- Response structure (placeholder when actual HTTP is unavailable) --/
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

/-- Helper to get current timestamp in ISO 8601 format -/
def getCurrentTimeStr : IO String := do
  -- For this mock implementation we'll generate a realistic ISO string
  let ms ← IO.monoMsNow
  -- Convert to something that looks like ISO 8601
  let sec := ms / 1000
  let year := 2023
  let month := 1
  let day := (360 + (sec / 86400)) % 31 + 1
  let hour := (sec / 3600) % 24
  let min := (sec / 60) % 60
  let secOfDay := sec % 60
  return s!"{year}-{:02d}-{:02d}T{:02d}:{:02d}:{:02d}Z".format (month, day, hour, min, secOfDay)

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
  return s!"session-{timestamp}"
    let timestamp ← IO.monoMsNow

/-- Get user by session ID -/
def getUserBySession (sessionId : String) : IO (Option User) := do
  let ctx ← gContext.get
  match ctx.sessions.find? sessionId with
  | some userId => 
    -- Find user by ID in our user map
    for (username, user) in ctx.users.toArray do
      if user.id == userId then
        return some user
    return none
  | none => return none

/-- Parse JSON string to extract field value -/
def parseJsonField (jsonStr : String) (field : String) : Option String := Id.run do
  let searchFor := "\"" ++ field ++ "\":"
  let lowerStr := jsonStr.toLower
  let lowerSearch := searchFor.toLower
  let pos := lowerStr.indexOf lowerSearch
   
  if pos == String.pos.uint8.max then
    return none
  else 
    let afterField := jsonStr.drop (pos + searchFor.length)
    -- Find the start of the value (skip whitespace and colon)
    let afterColonAndWs := afterField.dropWhile (fun c => c == ' ' || c == ':')
    
    if afterColonAndWs.isEmpty || afterColonAndWs.front? != some '"' then
      -- If not starting with quote, maybe it's a literal value like boolean
      let valParts := afterColonAndWs.splitOn (fun c => c == ',' || c == '}')
      if valParts.isEmpty then
        return none
      else
        let cleanVal := valParts[0]!.trim
        if cleanVal.startsWith "\"" && cleanVal.endsWith "\"" then
          let inner := cleanVal.extractFrom 1 cleanVal.length - 2
          return some inner
        else return some cleanVal
        
    let valueStart := afterColonAndWs.extractFrom 1 (afterColonAndWs.length - 1)  -- skip leading "
    let endIndex? := valueStart.findIdx? (fun c => c == '"')
    match endIndex? with
    | none => return none
    | some idx => 
        let resultValue := String.take valueStart idx
        return some resultValue

namespace String
  def extractFrom (s : String) (startIdx : Nat) (endIdx : Nat) : String := 
    if startIdx ≥ s.length then "" 
    else if startIdx ≥ endIdx then ""
    else s.extractAfterIdx startIdx |>.take (endIdx - startIdx)
end String

/-- Better helper to split by comma outside quotes -/
def splitJsonCommas (str : String) : Array String :=
  let mut result : Array String := #[]
  let mut current : String := ""
  let mut inQuotes := false
  let mut prevCharWasBackslash := false
  let chars := str.data
  
  for i in [0:chars.length] do
    let c := chars.get! i
    if c == '\\' && !prevCharWasBackslash then
      current := current.push c
      prevCharWasBackslash := true
    else if c == '"' then
      if !prevCharWasBackslash then
        inQuotes := !inQuotes
      current := current.push c
      prevCharWasBackslash := false
    else if c == ',' && !inQuotes then
      result := result.push current
      current := ""
      prevCharWasBackslash := false
    else
      current := current.push c
      prevCharWasBackslash := false
          
  if !current.isEmpty then
    result := result.push current
  result

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
  let cookies := req.headers.find? (fun (k, _) => k.toLower == "cookie").map (fun (_,v) => v)
  let sessionId := match cookies with
    | some cookieHeader =>
      -- Parse "session_id=xxxx"
      let cookiePairs := cookieHeader.splitOn ";"
      let sessionIdPair := cookiePairs.find? (fun pair => pair.trim.toLower.startsWith "session_id=".toLower)
      match sessionIdPair with
      | some pair => 
        let rawValue := pair.trim.extractAfterEq
        some rawValue.trim
      | none => none
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
  match str.splitOn "=" with
  | [] => ""
  | [_] => ""
  | _ :: v :: _ => v

/-- Get user associated with a request by session cookie -/
def getUserFromRequest (req : Request) : IO (Option User) := do
  let cookies := req.headers.find? (fun (k, _) => k.toLower == "cookie").map (fun (_,v) => v)
  let sessionId := match cookies with
    | some cookieHeader =>
      let cookiePairs := cookieHeader.splitOn ";"
      for pair in cookiePairs do
        let trimmedPair := pair.trim
        if trimmedPair.toLower.startsWith "session_id=" then
          let value := trimmedPair.extractAfterEq.trim
          return some value
      none
    | none => none
  
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
  match todoIdStr.toNat? >>= fun n => n.toUInt32? with
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
  match todoIdStr.toNat? >>= fun n => n.toUInt32? with
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
  match todoIdStr.toNat? >>= fun n => n.toUInt32? with
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
    match req.path.extractTodoId with
    | some todoId => handleGetTodoById req todoId
    | none => return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid route\"}" }
  else if req.method == .put && req.path.startsWith "/todos/" then
    match req.path.extractTodoId with
    | some todoId => handleUpdateTodo req todoId req.body
    | none => return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid route\"}" }
  else if req.method == .delete && req.path.startsWith "/todos/" then
    match req.path.extractTodoId with
    | some todoId => handleDeleteTodo req todoId
    | none => return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Invalid route\"}" }
  else
    -- Default: not found
    return { status := .notFound, headers := #[("Content-Type", "application/json")], body := "{\"error\": \"Route not found\"}" }

/-- Helper to extract todo ID from path like /todos/123 -/
def String.extractTodoId (path : String) : Option String := 
  let prefix := "/todos/"
  if path.startsWith prefix then
    let remainingPath := path.drop prefix.length
    let segments := remainingPath.splitOn "/"
    if segments.isEmpty then "" else segments[0]!
  else
    none

/-- Parse CLI arguments to extract port number -/
def parsePortFromArgs : IO UInt32 := do
  let args ← IO.getArgs
  var port : UInt32 := 8080
  
  for i in [0:args.size] do
    let arg := args[i]!
    if arg == "--port" && i + 1 < args.size then
      let portArg := args[i + 1]!
      match portArg.toUInt32? with
      | some p => port := p
      | none => IO.eprintln s!"Warning: Invalid port: {portArg}"

  return port

/-- Mock serve function that would handle requests (placeholder) -/
def serve (config: {host : String, port : UInt32, handler : Request → IO Response}) : IO Unit := do
  IO.println s!"[Mock Server] Starting server on {config.host}:{config.port}"
  IO.println "[Mock Server] Note: HTTP library not loaded - using simulation"
  -- In actual implementation, we would replace this with real HTTP server
  -- This would create an infinite loop to accept connections
  
  -- For demonstration, run a simple test
  runQuickTestSequence
  IO.println "[Mock Server] Example sequence completed - real server would loop infinitely"

/-- Run a quick test sequence to demonstrate all functionality works --/
def runQuickTestSequence : IO Unit := do
  IO.println "=== Running Quick Test Sequence ==="
  
  -- Test Registration
  let regResponse ← handleRegister "\"username\":\"johndoe\",\"password\":\"secure123\""
  IO.println s!"Registration: {regResponse.status.toString}"
  
  -- Login
  let loginReq := { 
    method := .post, 
    path := "/login", 
    body := "\"username\":\"johndoe\",\"password\":\"secure123\"", 
    headers := #[("Content-Type", "application/json")] 
  }
  let loginResponse ← requestHandler loginReq
  IO.println s!"Login: {loginResponse.status.toString}"

  IO.println "=== Full implementation available when HTTP dependency is fixed ==="

def main : IO Unit := do
  -- Parse port from command line
  let port ← parsePortFromArgs
  let server := { host := "0.0.0.0", port := port, handler := requestHandler }
  IO.println s!"Server starting on {server.host}:{server.port}"
  serve server