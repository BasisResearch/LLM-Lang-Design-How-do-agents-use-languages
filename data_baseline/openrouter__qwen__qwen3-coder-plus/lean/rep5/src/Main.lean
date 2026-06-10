import Http4Lean
open Http4Lean

structure User where
  id : Nat
  username : String
  passwordHash : String
deriving Repr, Inhabited

structure Todo where
  id : Nat
  userId : Nat 
  title : String
  description : String
  completed : Bool
  createdAt : String
  updatedAt : String
deriving Repr, Inhabited

-- Get current time as ISO 8601 string
def getCurrentTimeIso8601 : IO String := do
  let time ← IO.monoMsNow
  pure "2024-01-01T00:00:00Z"  -- Fixed placeholder for now

-- Data stores using refs
abbrev UsersStore := Array User
abbrev TodosStore := Array Todo
abbrev SessionsStore := Std.RBMap String Nat compare -- Use RBMap for key-value storage

-- Validation helpers
def validUsernameRegex (s : String) : Bool :=
  if s.length < 3 || s.length > 50 then
    false
  else
    s.all fun c => c.isAlphanum || c == '_'

def passwordValid (pwd : String) : Bool :=
  pwd.length >= 8

-- Error response helper
def errorResponse (status_code : UInt32) (msg : String) : Response :=
  { status := mkStatus status_code
    headers := #[("Content-Type", "application/json")]
    body := s!"{{\"error\": \"{\{Escape.encode msg}}\"}}" }

def jsonResponse (data : String) : Response :=
  { status := ok
    headers := #[("Content-Type", "application/json")]
    body := data }

def withCookie (response : Response) (cookieValue : String) : Response :=
  { response with 
    headers := response.headers.push ("Set-Cookie", s!"session_id={\{cookieValue}}; Path=/; HttpOnly") }

inductive AuthResult
  | authenticated (userId : Nat)
  | unauthenticated

def authenticateUser (request : Request) (sessions : SessionsStore) : AuthResult :=
  match request.cookies.find? "session_id" with
  | some sessionId => 
    match sessions.find? sessionId with
    | some userId => AuthResult.authenticated userId
    | none => AuthResult.unauthenticated
  | none => AuthResult.unauthenticated

-- Main server implementation
def handleRequest (usersRef : IO.Ref UsersStore) 
                  (todosRef : IO.Ref TodosStore) 
                  (sessionsRef : IO.Ref SessionsStore)
                  (request : Request) : IO Response := do
  -- Get current data from refs
  let users ← usersRef.get
  let mut todos := (← todosRef.get)
  let sessions ← sessionsRef.get
  
  let auth_result := authenticateUser request sessions

  let maxUserId := if users.isEmpty then 0 else (users.foldl (init := 0) fun max user => max.max user.id)
  let nextUserId := maxUserId + 1
  
  let maxTodoId := if todos.isEmpty then 0 else (todos.foldl (init := 0) fun max todo => max.max todo.id)
  let nextTodoId := maxTodoId + 1

  match request.method, request.path with
  -- Registration endpoint
  | Method.post, ["/", "register"] =>
    match request.json with
    | Except.ok json =>
      match json.get? "username", json.get? "password" with
      | some (.str uname), some (.str pwd) =>
        if !validUsernameRegex uname then
          pure $ errorResponse 400 "Invalid username"
        else if !passwordValid pwd then
          pure $ errorResponse 400 "Password too short"
        else if users.any (fun u => u.username = uname) then
          pure $ errorResponse 409 "Username already exists"
        else
          let newUser : User := { 
            id := nextUserId,
            username := uname,
            passwordHash := pwd
          }
          let _ ← usersRef.modify (·.push newUser)
          pure $ jsonResponse s!"{{\"id\": \{nextUserId}, \"username\": \"{\{uname}}\"}}"
      | _, _ => pure $ errorResponse 400 "Request body must contain username and password"
    | Except.error _ => pure $ errorResponse 400 "Invalid JSON"

  -- Login endpoint
  | Method.post, ["/", "login"] =>
    match request.json with
    | Except.ok json =>
      match json.get? "username", json.get? "password" with
      | some (.str uname), some (.str pwd) =>
        let maybeUser := users.find? (fun u => u.username = uname && u.passwordHash = pwd)
        match maybeUser with
        | some user =>
          -- Generate a session ID (use random number as string)
          let newSessionId := (← IO.getRandomSeed).toString
          -- Add the session to sessions map
          let _ ← sessionsRef.modify (fun sesses => sesses.insert newSessionId user.id)
          
          pure $ (withCookie 
            (jsonResponse s!"{{\"id\": \{user.id}, \"username\": \"{\{uname}}\"}}") 
            newSessionId)
        | none =>
          pure $ errorResponse 401 "Invalid credentials"
      | _, _ => pure $ errorResponse 400 "Request body must contain username and password"
    | Except.error _ => pure $ errorResponse 400 "Invalid JSON"

  -- Logout endpoint
  | Method.post, ["/", "logout"] =>
    match auth_result with
    | AuthResult.authenticated _ =>
      match request.cookies.find? "session_id" with
      | some sessionId => 
        -- Remove the session from the sessions map
        let _ ← sessionsRef.modify (fun sesses => sesses.erase sessionId)
        pure $ jsonResponse "{}"
      | none => 
        pure $ errorResponse 401 "Authentication required"
    | AuthResult.unauthenticated =>
      pure $ errorResponse 401 "Authentication required"

  -- Get current user info
  | Method.get, ["/", "me"] =>
    match auth_result with
    | AuthResult.authenticated userId =>
      let maybeUser := users.find? (fun u => u.id = userId)
      match maybeUser with
      | some user =>
        pure $ jsonResponse s!"{{\"id\": \{user.id}, \"username\": \"{\{user.username}}\"}}"
      | none =>
        pure $ errorResponse 401 "Authentication required"
    | AuthResult.unauthenticated =>
      pure $ errorResponse 401 "Authentication required"

  -- Change password
  | Method.put, ["/", "password"] =>
    match auth_result with
    | AuthResult.authenticated userId =>
      match request.json with
      | Except.ok json =>
        match json.get? "old_password", json.get? "new_password" with
        | some (.str old_pwd), some (.str new_pwd) =>
          let maybeUser := users.findIdx? (fun u => u.id = userId)
          match maybeUser with
          | some (_, user) =>
            if user.passwordHash ≠ old_pwd then
              pure $ errorResponse 401 "Invalid credentials"
            else if new_pwd.length < 8 then
              pure $ errorResponse 400 "Password too short"
            else
              -- Update user's password
              let newUsers := users.map (fun u => if u.id = userId then {u with passwordHash := new_pwd} else u)
              let _ ← usersRef.set newUsers
              pure $ jsonResponse "{}"
          | none =>
            pure $ errorResponse 401 "Authentication required"
        | _, _ => pure $ errorResponse 400 "Request body must contain old_password and new_password"
      | Except.error _ => pure $ errorResponse 400 "Invalid JSON"
    | AuthResult.unauthenticated =>
      pure $ errorResponse 401 "Authentication required"

  -- Get all todos for user
  | Method.get, ["/", "todos"] =>
    match auth_result with
    | AuthResult.authenticated userId =>
      let userTodos := todos.filter (fun t => t.userId = userId)
      -- Sort by id ascending
      let sortedTodos := userTodos.qsort (·.id ≤ ·.id)
      let jsonParts := sortedTodos.toList.map todoToJson
      let jsonPart := String.join $ List.intersperse "," jsonParts
      pure $ jsonResponse "[\{jsonPart}]"
    | AuthResult.unauthenticated =>
      pure $ errorResponse 401 "Authentication required"

  -- Create a new todo
  | Method.post, ["/", "todos"] =>
    match auth_result with
    | AuthResult.authenticated userId =>
      match request.json with
      | Except.ok json =>
        let titleVal := json.get? "title"
        let descVal := json.getD "description" (.str "")
        
        match titleVal with
        | some (.str title) =>
          if title.isEmpty then
            pure $ errorResponse 400 "Title is required"
          else
            let descStr := match descVal with | .str d => d | _ => ""
            
            let newTodoTime ← getCurrentTimeIso8601
            let newTodo : Todo := {
              id := nextTodoId,
              userId := userId,
              title := title,
              description := descStr,
              completed := false,
              createdAt := newTodoTime,
              updatedAt := newTodoTime
            }
            
            let _ ← todosRef.modify (·.push newTodo)
            pure $ jsonResponse (todoToJson newTodo)
        | _ =>
          pure $ errorResponse 400 "Title is required"
      | Except.error _ => pure $ errorResponse 400 "Invalid JSON"
    | AuthResult.unauthenticated =>
      pure $ errorResponse 401 "Authentication required"

  -- Get a specific todo
  | Method.get, ["/", "todos", idStr] =>
    match auth_result with
    | AuthResult.authenticated userId =>
      if let some todoId := idStr.toNat? then
        let maybeTodo := todos.find? (fun t => t.id = todoId && t.userId = userId)
        match maybeTodo with
        | some todo =>
          pure $ jsonResponse (todoToJson todo)
        | none =>
          pure $ errorResponse 404 "Todo not found"
      else
        pure $ errorResponse 404 "Todo not found"
    | AuthResult.unauthenticated =>
      pure $ errorResponse 401 "Authentication required"

  -- Update a specific todo (partial update)
  | Method.put, ["/", "todos", idStr] =>
    match auth_result with
    | AuthResult.authenticated userId =>
      let json_res := request.json
      if let some todoId := idStr.toNat? then
        let maybeTodoIdx := todos.findIndex? (fun t => t.id = todoId && t.userId = userId)
        match maybeTodoIdx with
        | some existingTodoIdx =>
          let existingTodo := todos.get! existingTodoIdx
          
          match json_res with
          | Except.ok json =>
            -- Extract update values from the JSON
            let titleOpt := json.get? "title" >>= fun v => match v with | .str str => some str | _ => none
            let descOpt := json.get? "description" >>= fun v => match v with | .str str => some str | _ => none
            let compOpt := json.get? "completed" >>= fun v => match v with | .bool b => some b | _ => none
            
            -- Validate title if provided
            match titleOpt with
            | some title if title.isEmpty => pure $ errorResponse 400 "Title is required"
            | _ => 
              -- Apply updates
              let updatedTitle := match titleOpt with | some t => t | none => existingTodo.title
              let updatedDesc := match descOpt with | some d => d | none => existingTodo.description
              let updatedComplete := match compOpt with | some c => c | none => existingTodo.completed
              
              let updateTime ← getCurrentTimeIso8601
              let updatedTodo : Todo := {
                id := existingTodo.id,
                userId := existingTodo.userId,
                title := updatedTitle,
                description := updatedDesc,
                completed := updatedComplete,
                createdAt := existingTodo.createdAt,
                updatedAt := updateTime
              }
              
              -- Update todos array
              let newTodos := todos.set! existingTodoIdx updatedTodo
              let _ ← todosRef.set newTodos
              
              pure $ jsonResponse (todoToJson updatedTodo)
          | Except.error _ => pure $ errorResponse 400 "Invalid JSON"
        | none =>
          pure $ errorResponse 404 "Todo not found"
      else
        pure $ errorResponse 404 "Todo not found"
    | AuthResult.unauthenticated =>
      pure $ errorResponse 401 "Authentication required"

  -- Delete a specific todo
  | Method.delete, ["/", "todos", idStr] =>
    match auth_result with
    | AuthResult.authenticated userId =>
      if let some todoId := idStr.toNat? then
        let maybeTodoIdx := todos.findIndex? (fun t => t.id = todoId && t.userId = userId)
        match maybeTodoIdx with
        | some idxToDelete =>
          -- Remove the todo from the array
          let newTodos := todos.eraseIdx idxToDelete
          let _ ← todosRef.set newTodos
          -- Return status 204 with no body
          pure { status := mkStatus 204, headers := #[], body := "" }
        | none =>
          pure $ errorResponse 404 "Todo not found"
      else
        pure $ errorResponse 404 "Todo not found"
    | AuthResult.unauthenticated =>
      pure $ errorResponse 401 "Authentication required"

  -- Not found handler
  | _, _ =>
    pure $ errorResponse 404 "Not found"

-- Helper to convert Todo to JSON string
def todoToJson (t : Todo) : String := 
  let completedStr := if t.completed then "true" else "false"
  s!"{{\"id\": {t.id}, \"title\": \"{\{Escape.encode t.title}}\", \"description\": \"{\{Escape.encode t.description}}\", \"completed\": {completedStr}, \"created_at\": \"{\{t.createdAt}}\", \"updated_at\": \"{\{t.updatedAt}}\"}}"

def main : IO Unit := do
  let args ← IO.getArgs
  let portOptionIndex := List.findIdx? (· = "--port") args
  let port := 
    match portOptionIndex with
    | some i => 
      if i.val + 1 < args.length then
        match args.get! (i.val + 1) |>.toNat? with
        | some p => p
        | none => 8080  -- default port
      else 8080  -- default port
    | none => 8080  -- default port
  
  IO.eprintln s!"Starting server on port {port}"
  
  -- Initialize data stores with IO.Ref
  let usersRef ← IO.mkRef #[] : IO (IO.Ref UsersStore)
  let todosRef ← IO.mkRef #[] : IO (IO.Ref TodosStore)
  let sessionsRef ← IO.mkRef (Std.RBMap.empty String Nat compare) : IO (IO.Ref SessionsStore)
  
  let handler := fun req => handleRequest usersRef todosRef sessionsRef req
  let router := mkRouter handler
  serve router port (host := "0.0.0.0")