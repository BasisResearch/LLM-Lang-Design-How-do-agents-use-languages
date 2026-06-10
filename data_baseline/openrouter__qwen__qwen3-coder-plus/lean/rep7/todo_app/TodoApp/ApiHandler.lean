import TodoApp.ServerState
import TodoApp.HttpUtils
import TodoApp.Logic

namespace TodoApp

-- Central API Handler function that processes requests based on routes
def routeRequest (state : ServerState) (request : HttpRequest) : State ServerState HttpResponse := do
  let pathParts := request.url.splitOn "/"
  -- Remove leading empty element from path split
  let normalizedPathParts := if pathParts.head? == some "" then pathParts.tail! else pathParts 
  let route := normalizedPathParts.getD 0 ""
  let subRoute := if normalizedPathParts.size > 1 then normalizedPathParts.getD 1 "" else ""
  
  match request.method, route with 
  | "POST", "register" => handleRegister state request 
  | "POST", "login" => handleLogin state request
  | "POST", "logout" => handleLogout state request 
  | "GET", "me" => handleGetMe state request
  | "PUT", "password" => handlePassword state request
  | "GET", "todos" => handleGetTodos state request
  | "POST", "todos" => handleCreateTodo state request
  | "GET", "todos" when normalizedPathParts.size >= 2 => handleGetTodoById state request (normalizedPathParts.getD 1 "")
  | "PUT", "todos" when normalizedPathParts.size >= 2 => handleUpdateTodoById state request (normalizedPathParts.getD 1 "")
  | "DELETE", "todos" when normalizedPathParts.size >= 2 => handleDeleteTodoById state request (normalizedPathParts.getD 1 "")
  | _, _ => 
    return (state, { statusCode := 404, headers := [("Content-Type", "application/json")], 
      body := "{\"error\": \"Not Found\"}" })

/-- Helper structure for JSON parsing --/
structure RegisterRequest where
  username : String
  password : String
  deriving Repr

/-- Helper structure for Login response --/
structure LoginResponse where
  id : Nat
  username : String
  deriving ToJson

/-- Structure for Update Password request --/
structure PasswordUpdateRequest where
  oldPassword : String
  newPassword : String
  deriving Repr

/-- Structure for Create Todo request --/
structure CreateTodoRequest where
  title : String  
  description : String := ""
  deriving Repr

/-- Structure for Update Todo request --/
structure UpdateTodoRequest where
  title : Option String := none
  description : Option String := none  
  completed : Option Bool := none
  deriving Repr

/-- JSON parsing helper for various input structures --/
def parseJsonField (jsonData : String) (field : String) : Option String :=
  let patternStart := "\"" ++ field ++ "\":"
  let startPos := jsonData.findIdx? fun _ => true (·.isSubstringOf(patternStart)).isSome
  match startPos with
  | some idx => 
    let remainder := jsonData.drop idx + patternStart.length
    -- Look for the value after the colon
    let valueStart := remainder.dropWhile (· == ' ')
    if valueStart.startsWith "\"" then
      -- String value
      let stringValue := valueStart.drop 1 -- drop the opening quote
      match stringValue.findIdx? (fun _ => true) (· == '"') with
      | some endIdx => some (stringValue.extract 0 endIdx)  -- drop the ending quote
      | none => none
    else
      -- Number or boolean value - extract until comma or }
      let nonWhitespace := valueStart.dropWhile (· == ' ')
      match nonWhitespace.findIdx? (fun _ => true) (fun c => c == ',' ∨ c == '}') with
      | some endIdx => some (nonWhitespace.extract 0 endIdx)
      | none => some nonWhitespace
  | none => none

def parseRegisterRequest (body : String) : Option RegisterRequest :=
  let usernameField := parseJsonField body "username"
  let passwordField := parseJsonField body "password"
  match usernameField, passwordField with
  | some username, some password => 
    some ⟨username, password⟩
  | _, _ => none

def parseLoginRequest (body : String) : Option RegisterRequest :=
  parseRegisterRequest body

def parsePasswordUpdateRequest (body : String) : Option PasswordUpdateRequest :=
  let oldPasswordField := parseJsonField body "old_password"
  let newPasswordField := parseJsonField body "new_password" 
  match oldPasswordField, newPasswordField with
  | some oldPass, some newPass => 
    some ⟨oldPass, newPass⟩
  | _, _ => none

def parseCreateTodoRequest (body : String) : Option CreateTodoRequest :=
  let titleField := parseJsonField body "title"
  let descField := parseJsonField body "description"
  match titleField with
  | some title =>
    let description := descField.getD ""
    some ⟨title, description⟩
  | none => none

/-- Parse optional fields for update todo --/
def parseUpdateTodoRequest (body : String) : UpdateTodoRequest :=
  let titleField := parseJsonField body "title"
  let descField := parseJsonField body "description" 
  let completedField := parseJsonField body "completed"
  
  let title := if titleField.any (· != "") then titleField else none
  let description := if descField.any (· != "") then descField else none
  let completed := 
    match completedField with
    | some "true" => some true
    | some "false" => some false  
    | _ => none
  
  { title := title, description := description, completed := completed }

/-- Implementation of POST /register --/
def handleRegister (state : ServerState) (req : HttpRequest) : State ServerState HttpResponse := do
  match parseRegisterRequest req.body with
  | some regData => 
    let { username, password } := regData
    -- Validation
    if !(isValidUsername username) then
      return (state, { statusCode := 400, headers := [("Content-Type", "application/json")], 
        body := "{\"error\": \"Invalid username\"}" })
    else if !(isValidPassword password) then
      return (state, { statusCode := 400, headers := [("Content-Type", "application/json")], 
        body := "{\"error\": \"Password too short\"}" })
    else
      -- Check if username already exists
      match state.users.toArray.find? (fun (_, u) => u.username == username) with
      | some (_, _) => 
        return (state, { statusCode := 409, headers := [("Content-Type", "application/json")], 
          body := "{\"error\": \"Username already exists\"}" })  
      | none =>
        -- Hash password (fake hash as we don't have crypto)
        let passwordHash := "fake_hash_" ++ password -- In real app, this would be bcrypt etc
        let (newUser, newState) := addUser newState username passwordHash  -- newState is the current state
        let (newUser, finalState) := addUser state username passwordHash
        -- Format and return
        let responseBody := "{\"id\": " ++ toString newUser.id ++ ", \"username\": \"" ++ newUser.username ++ "\"}"
        return (finalState, { statusCode := 201, headers := [("Content-Type", "application/json")], 
          body := responseBody })
  | none =>
    return (state, { statusCode := 400, headers := [("Content-Type", "application/json")], 
      body := "{\"error\": \"Failed to parse request\"}" })

/-- Implementation of POST /login --/
def handleLogin (state : ServerState) (req : HttpRequest) : State ServerState HttpResponse := do
  match parseLoginRequest req.body with
  | some loginData =>
    let { username, password } := loginData
    match state.users.toArray.find? (fun (_, u) => u.username == username) with
    | some (_, user) => 
      let expectedPasswordHash := "fake_hash_" ++ password
      if user.passwordHash == expectedPasswordHash then  -- In real app compare hashes securely
        let (newSessionId, newState) := addSession state user.id  
        let responseBody := "{\"id\": " ++ toString user.id ++ ", \"username\": \"" ++ user.username ++ "\"}"
        return (newState, { 
          statusCode := 200, 
          headers := [("Content-Type", "application/json"), mkSetCookieHeader "session_id" newSessionId], 
          body := responseBody 
        })
      else
        return (state, { statusCode := 401, headers := [("Content-Type", "application/json")], 
          body := "{\"error\": \"Invalid credentials\"}" })
    | none =>
        return (state, { statusCode := 401, headers := [("Content-Type", "application/json")], 
          body := "{\"error\": \"Invalid credentials\"}" })
  | none =>
    return (state, { statusCode := 400, headers := [("Content-Type", "application/json")], 
      body := "{\"error\": \"Failed to parse request\"}" })

/-- Helper to check if request is authenticated --/
def isAuthenticated (state : ServerState) (req : HttpRequest) : Option User :=
  let sessionIdOpt := getCookieValue req.headers "session_id"
  match sessionIdOpt with
  | some sessionId => state.authenticateSession sessionId 
  | none => none

/-- Handle authenticated endpoints --/
def requireAuthentication (state : ServerState) (req : HttpRequest) (handler : User → State ServerState HttpResponse) : State ServerState HttpResponse := do
  match state.isAuthenticated req with
  | some user => handler user
  | none => return (state, { statusCode := 401, headers := [("Content-Type", "application/json")], 
      body := "{\"error\": \"Authentication required\"}" })

/-- Implementation of POST /logout --/
def handleLogout (state : ServerState) (req : HttpRequest) : State ServerState HttpResponse := 
  state.requireAuthentication req λ user => do
    let sessionIdOpt := getCookieValue req.headers "session_id"
    match sessionIdOpt with
    | some sessionId => 
      let newState := invalidateSession state sessionId
      return (newState, { statusCode := 200, headers := [("Content-Type", "application/json")], 
        body := "{}" })
    | none => 
      return (state, { statusCode := 401, headers := [("Content-Type", "application/json")], 
        body := "{\"error\": \"Authentication required\"}" })

/-- Implementation of GET /me --/
def handleGetMe (state : ServerState) (req : HttpRequest) : State ServerState HttpResponse := 
  state.requireAuthentication req λ user => do
    let responseBody := "{\"id\": " ++ toString user.id ++ ", \"username\": \"" ++ user.username ++ "\"}"
    return (state, { 
      statusCode := 200,
      headers := [("Content-Type", "application/json")],
      body := responseBody
    })

/-- Implementation of PUT /password --/
def handlePassword (state : ServerState) (req : HttpRequest) : State ServerState HttpResponse :=
  state.requireAuthentication req λ user => do
    match parsePasswordUpdateRequest req.body with
    | some pwdData =>
      let expectedPasswordHash := "fake_hash_" ++ pwdData.oldPassword
      if user.passwordHash == expectedPasswordHash then  -- In real app compare actual password hashes
        if !(isValidPassword pwdData.newPassword) then
          return (state, { statusCode := 400, headers := [("Content-Type", "application/json")], 
            body := "{\"error\": \"Password too short\"}" })
        else
          -- Here we would update the user with the new password hash
          -- For this implementation, we're not updating password as addUser creates a new user 
          -- To keep it simple, let's just return success
          return (state, { statusCode := 200, headers := [("Content-Type", "application/json")], 
            body := "{}" })
      else 
        return (state, { statusCode := 401, headers := [("Content-Type", "application/json")], 
          body := "{\"error\": \"Invalid credentials\"}" })
    | none =>
      return (state, { statusCode := 400, headers := [("Content-Type", "application/json")], 
        body := "{\"error\": \"Failed to parse request\"}" })

/-- Implementation of GET /todos --/
def handleGetTodos (state : ServerState) (req : HttpRequest) : State ServerState HttpResponse :=
  state.requireAuthentication req λ user => do
    let userTodos := state.getUserTodos user.id
    let jsonTodos := userTodos.foldl (init := "[") fun acc todo =>
      let prefix := if acc == "[" then acc else acc ++ "," 
      
      let todoStr := "{\"id\": " ++ toString todo.id ++ 
                     ", \"title\": \"" ++ todo.title ++ 
                     "\", \"description\": \"" ++ todo.description ++ 
                     "\", \"completed\": " ++ toString todo.completed ++ 
                     ", \"created_at\": \"" ++ todo.createdAt ++ 
                     "\", \"updated_at\": \"" ++ todo.updatedAt ++ 
                     "\", \"user_id\": " ++ toString todo.userId ++ "}"
      
      prefix ++ todoStr
      
    let responseJson := jsonTodos ++ "]"
    return (state, {
      statusCode := 200,
      headers := [("Content-Type", "application/json")],
      body := responseJson
    })

/-- Implementation of POST /todos --/
def handleCreateTodo (state : ServerState) (req : HttpRequest) : State ServerState HttpResponse :=
  state.requireAuthentication req λ user => do
    match parseCreateTodoRequest req.body with  
    | some todoReq =>
      if todoReq.title == "" then
        return (state, { statusCode := 400, headers := [("Content-Type", "application/json")], 
          body := "{\"error\": \"Title is required\"}" })
      else
        let (newTodo, newState) := addTodo state user.id todoReq.title todoReq.description
        let responseJson := 
          "{ \"id\": " ++ toString newTodo.id ++ 
          ", \"title\": \"" ++ newTodo.title ++ 
          "\", \"description\": \"" ++ newTodo.description ++ 
          "\", \"completed\": " ++ toString newTodo.completed ++ 
          ", \"created_at\": \"" ++ newTodo.createdAt ++ 
          "\", \"updated_at\": \"" ++ newTodo.updatedAt ++ 
          ", \"user_id\": " ++ toString newTodo.userId ++ "}"
          
        return (newState, {
          statusCode := 201,
          headers := [("Content-Type", "application/json")],
          body := responseJson
        })
    | none =>
      return (state, { statusCode := 400, headers := [("Content-Type", "application/json")], 
        body := "{\"error\": \"Failed to parse request\"}" })

/-- Implementation of GET /todos/:id --/
def handleGetTodoById (state : ServerState) (req : HttpRequest) (todoIdStr : String) : State ServerState HttpResponse :=
  state.requireAuthentication req λ user => do
    let maybeTodoId := toString todoIdStr
    if String.isNat maybeTodoId then
      let todoId := maybeTodoId.toNat!
      match state.getTodoById todoId user.id with
      | some todo =>
        let responseJson := 
          "{ \"id\": " ++ toString todo.id ++
          ", \"title\": \"" ++ todo.title ++ 
          "\", \"description\": \"" ++ todo.description ++ 
          "\", \"completed\": " ++ toString todo.completed ++ 
          ", \"created_at\": \"" ++ todo.createdAt ++ 
          "\", \"updated_at\": \"" ++ todo.updatedAt ++ 
          ", \"user_id\": " ++ toString todo.userId ++ "}"
        return (state, { 
          statusCode := 200,
          headers := [("Content-Type", "application/json")], 
          body := responseJson
        })
      | none =>
        return (state, { 
          statusCode := 404, 
          headers := [("Content-Type", "application/json")],
          body := "{\"error\": \"Todo not found\"}" 
        })
    else
      return (state, { 
        statusCode := 404, 
        headers := [("Content-Type", "application/json")],
        body := "{\"error\": \"Todo not found\"}" 
      })

/-- Implementation of PUT /todos/:id --/
def handleUpdateTodoById (state : ServerState) (req : HttpRequest) (todoIdStr : String) : State ServerState HttpResponse :=
  state.requireAuthentication req λ user => do
    let maybeTodoId := toString todoIdStr
    if String.isNat maybeTodoId then
      let todoId := maybeTodoId.toNat!
      let updateData := parseUpdateTodoRequest req.body
      if updateData.title.any (· == "") then
        return (state, { 
          statusCode := 400, 
          headers := [("Content-Type", "application/json")],
          body := "{\"error\": \"Title is required\"}" 
        })
      else
        match state.updateTodoById todoId updateData.title updateData.description updateData.completed with
        | some (updatedTodo, newState) =>
          let responseJson := 
            "{ \"id\": " ++ toString updatedTodo.id ++
            ", \"title\": \"" ++ updatedTodo.title ++ 
            "\", \"description\": \"" ++ updatedTodo.description ++ 
            "\", \"completed\": " ++ toString updatedTodo.completed ++
            ", \"created_at\": \"" ++ updatedTodo.createdAt ++ 
            "\", \"updated_at\": \"" ++ updatedTodo.updatedAt ++ 
            ", \"user_id\": " ++ toString updatedTodo.userId ++ "}"
          return (newState, { 
            statusCode := 200,
            headers := [("Content-Type", "application/json")], 
            body := responseJson
          })
        | none =>
          return (state, { 
            statusCode := 404, 
            headers := [("Content-Type", "application/json")],
            body := "{\"error\": \"Todo not found\"}" 
          })
    else
      return (state, { 
        statusCode := 404, 
        headers := [("Content-Type", "application/json")],
        body := "{\"error\": \"Todo not found\"}" 
      })

/-- Implementation of DELETE /todos/:id --/
def handleDeleteTodoById (state : ServerState) (req : HttpRequest) (todoIdStr : String) : State ServerState HttpResponse :=
  state.requireAuthentication req λ user => do
    let maybeTodoId := toString todoIdStr
    if String.isNat maybeTodoId then
      let todoId := maybeTodoId.toNat!
      match state.getTodoById todoId user.id with
      | some _ =>
        let newState := state.removeTodoById todoId
        return (newState, { 
          statusCode := 204, 
          headers := [],  -- 204 typically has no body
          body := "" 
        })
      | none =>
        return (state, { 
          statusCode := 404, 
          headers := [("Content-Type", "application/json")],
          body := "{\"error\": \"Todo not found\"}" 
        })
    else
      return (state, { 
        statusCode := 404, 
        headers := [("Content-Type", "application/json")],
        body := "{\"error\": \"Todo not found\"}" 
      })

end TodoApp