import Std.Internal.UV.TCP
import Std.Net.Addr

open Std.Net
open Std.Internal.UV.TCP.Socket

structure HRequest where
  method : String
  path : String
  headers : List (String × String)
  body : String

def parseRequest (s : String) : Option HRequest := do
  let lines := s.splitOn "\r\n"
  let firstLine := lines.head?
  if firstLine.isNone then return none
  let fl := firstLine.get!.splitOn " "
  let method := fl.head?
  let fullpath := fl.get! 1 ""
  if method.isNone then return none
  let m := method.get!
  let pathParts := fullpath.splitOn "?"
  let path := pathParts.head?.getD fullpath

  let mut headers : List (String × String) := []
  let mut body := ""
  let mut bodyStart := lines.length
  let mut i := 1
  while i < lines.length do
    let line := lines.get! i ""
    if line == "" then
      bodyStart := i
      break
    let parts := line.splitOn ":"
    if parts.length >= 2 then
      let name := parts.head?.getD ""
      let valParts := parts.drop 1
      let val := String.join valParts
      headers := headers ++ [(name.trimAscii.toString, val.trimAscii.toString)]
    i := i + 1

  let bodyLines := lines.drop (bodyStart + 1)
  body := String.join bodyLines
  
  pure { method := m, path, headers, body }

def extractJsonField (s : String) (key : String) : Option String :=
  let target := "\"" ++ key ++ "\": \""
  match s.splitOn target with
  | [_] => none
  | _ :: rest :: _ =>
    match rest.splitOn "\"" with
    | [val, _] => some val
    | val :: _ => some val
    | [] => none
  | _ => none

def extractJsonBool (s : String) (key : String) : Option Bool :=
  let targetT := "\"" ++ key ++ "\": true"
  let targetF := "\"" ++ key ++ "\": false"
  if s.contains targetT then some true
  else if s.contains targetF then some false
  else none

def toJsonObject (pairs : List (String × String)) : String :=
  let elems := pairs.map fun (k, v) => "\"" ++ k ++ "\": " ++ v
  "{ " ++ String.join (elems.intersperse ", ") ++ " }"

def toJsonArray (arr : List String) : String :=
  "[ " ++ String.join (arr.intersperse ", ") ++ " ]"

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
  toJsonObject
    [ ("id", toString t.id),
      ("title", "\"" ++ t.title ++ "\""),
      ("description", "\"" ++ t.description ++ "\""),
      ("completed", toString t.completed),
      ("created_at", "\"" ++ t.createdAt ++ "\""),
      ("updated_at", "\"" ++ t.updatedAt ++ "\"") ]

def userToJson (u : User) : String :=
  toJsonObject [ ("id", toString u.id), ("username", "\"" ++ u.username ++ "\"") ]

structure AppState where
  users : List User
  todos : List Todo
  sessions : List (String × Nat)
  nextUserId : Nat
  nextTodoId : Nat

def initialState : AppState :=
  { users := [], todos := [], sessions := [], nextUserId := 1, nextTodoId := 1 }

structure ServerState where
  state : AppState

def getCurrentTime : IO String :=
  pure "2025-06-04T12:00:00Z"

def generateToken : IO String := do
  let rand ← IO.rand 0 999999999
  pure ("sess-" ++ toString rand)

def findUser (state : AppState) (username : String) : Option User :=
  state.users.find? (fun u => u.username == username)

def findUserById (state : AppState) (id : Nat) : Option User :=
  state.users.find? (fun u => u.id == id)

def findSession (state : AppState) (token : String) : Option Nat :=
  match state.sessions.find? (fun (t, _) => t == token) with
  | some (_, uid) => some uid
  | none => none

def getSessionFromHeaders (headers : List (String × String)) : Option String := do
  match headers.find? (fun (k, _) => k.toLower == "cookie") with
  | some (_, c) =>
    let parts := c.splitOn ";"
    match parts.find? (fun p => p.trimAscii.toString.startsWith "session_id=") with
    | some s => pure (s.trimAscii.toString.drop "session_id=".length)
    | none => pure none
  | none => pure none

def isValidUsername (u : String) : Bool :=
  u.length >= 3 && u.length <= 50 && u.toList.all (fun c => c.isAlpha || c.isDigit || c == '_')

def isUsernameTaken (state : AppState) (u : String) : Bool :=
  state.users.any (fun user => user.username == u)

def validatePassword (p : String) : Bool := p.length >= 8

structure HttpResponse where
  status : String
  headers : List (String × String)
  body : Option String

def buildResponse (status : String) (headers : List (String × String)) (body : Option String) : HttpResponse :=
  { status, headers, body }

def jsonResponse (status : String) (body : String) : HttpResponse :=
  buildResponse status [("Content-Type", "application/json")] (some body)

def jsonOk (body : String) : HttpResponse :=
  jsonResponse "200 OK" body

def jsonCreated (body : String) : HttpResponse :=
  jsonResponse "201 Created" body

def jsonError (status : String) (msg : String) : HttpResponse :=
  jsonResponse status (toJsonObject [("error", "\"" ++ msg ++ "\"")])

def unauthResponse : HttpResponse :=
  jsonError "401 Unauthorized" "Authentication required"

def notFoundResponse : HttpResponse :=
  jsonError "404 Not Found" "Todo not found"

def serializeResponse (r : HttpResponse) : String :=
  let statusLine := "HTTP/1.1 " ++ r.status ++ "\r\n"
  let headerLines := r.headers.map (fun (k, v) => k ++ ": " ++ v)
  let hStr := String.join (headerLines.intersperse "\r\n")
  let bodyStr := Option.getD r.body ""
  statusLine ++ hStr ++ "\r\n\r\n" ++ bodyStr

def listSet (l : List α) (idx : Nat) (val : α) : List α :=
  let rec go (l : List α) (i : Nat) : List α :=
    match l with
    | [] => []
    | h :: t => if i == 0 then val :: t else h :: go t (i - 1)
  go l idx

def listEraseIdx (l : List α) (idx : Nat) : List α :=
  let rec go (l : List α) (i : Nat) : List α :=
    match l with
    | [] => []
    | h :: t => if i == 0 then t else h :: go t (i - 1)
  go l idx

def listFindIdx? (p : α → Bool) (l : List α) : Option Nat :=
  let rec go (l : List α) (i : Nat) : Option Nat :=
    match l with
    | [] => none
    | h :: t => if p h then some i else go t (i + 1)
  go l 0

def stringToByteArray (s : String) : ByteArray :=
  ByteArray.mk (s.toList.toArray.map (fun c => c.toNat.toUInt8))

def main : IO UInt32 := do
  let args ← IO.getArgs
  let mut port : Nat := 8080
  let mut i := 0
  while i < args.length do
    if args.get? i == some "--port" && i + 1 < args.length then
      port := (args.get? (i + 1) |>.getD "8080").toNat?.getD 8080
      i := i + 2
    else
      i := i + 1
  
  let port16 : UInt16 := port.toUInt16
  
  let sock ← new
  let addr := SocketAddress.v4 ⟨{ octets := Vector.mk #[0, 0, 0, 0] rfl }, port16⟩
  sock.bind addr
  sock.listen 10
  IO.println s!"Listening on 0.0.0.0:{port}..."
  
  let stateRef ← IO.Ref.new { state := initialState }
  
  let rec loop : IO Unit := do
    let clientResult ← tryAccept sock
    match clientResult with
    | Except.ok (some client) => do
      let readable ← client.waitReadable
      let res ← readable.result?.get
      if res == some (.ok true) then
        let dataPromise ← client.recv? 4096
        let dataRes ← dataPromise.result?.get
        if let some (.ok (some bytes)) := dataRes then
          let s := String.fromUTF8Unchecked bytes
          match parseRequest s with
          | some req =>
            let oldState ← stateRef.get
            let resp : HttpResponse := 
              if req.method == "POST" && req.path == "/register" then
                let uStr := extractJsonField req.body "username"
                let pStr := extractJsonField req.body "password"
                if uStr.isNone || pStr.isNone then
                  jsonError "400 Bad Request" "Invalid username"
                else
                  let u := uStr.get!
                  let p := pStr.get!
                  if not (isValidUsername u) then
                    jsonError "400 Bad Request" "Invalid username"
                  else if not (validatePassword p) then
                    jsonError "400 Bad Request" "Password too short"
                  else if isUsernameTaken oldState.state u then
                    jsonError "409 Conflict" "Username already exists"
                  else
                    let newUser := { id := oldState.state.nextUserId, username := u, password := p }
                    stateRef.set { oldState with state := { oldState.state with users := oldState.state.users ++ [newUser], nextUserId := oldState.state.nextUserId + 1 } }
                    jsonCreated (userToJson newUser)
              else if req.method == "POST" && req.path == "/login" then
                let uStr := extractJsonField req.body "username"
                let pStr := extractJsonField req.body "password"
                if uStr.isNone || pStr.isNone then
                  jsonError "401 Unauthorized" "Invalid credentials"
                else
                  let u := uStr.get!
                  let p := pStr.get!
                  match findUser oldState.state u with
                  | some user =>
                    if user.password != p then
                      jsonError "401 Unauthorized" "Invalid credentials"
                    else
                      let token ← generateToken
                      stateRef.set { oldState with state := { oldState.state with sessions := oldState.state.sessions ++ [(token, user.id)] } }
                      let cookie := "session_id=" ++ token ++ "; Path=/; HttpOnly"
                      buildResponse "200 OK" [("Content-Type", "application/json"), ("Set-Cookie", cookie)] (some (userToJson user))
                  | none =>
                    jsonError "401 Unauthorized" "Invalid credentials"
              else if req.method == "POST" && req.path == "/logout" then
                let tokenOpt := getSessionFromHeaders req.headers
                if tokenOpt.isNone then unauthResponse
                else
                  let token := tokenOpt.get!
                  match findSession oldState.state token with
                  | none => unauthResponse
                  | some _ =>
                    let newSessions := oldState.state.sessions.filter (fun (t, _) => t != token)
                    stateRef.set { oldState with state := { oldState.state with sessions := newSessions } }
                    jsonOk "{}"
              else if req.method == "GET" && req.path == "/me" then
                let tokenOpt := getSessionFromHeaders req.headers
                if tokenOpt.isNone then unauthResponse
                else
                  let token := tokenOpt.get!
                  match findSession oldState.state token with
                  | none => unauthResponse
                  | some userId =>
                    match findUserById oldState.state userId with
                    | none => unauthResponse
                    | some user => jsonOk (userToJson user)
              else if req.method == "PUT" && req.path == "/password" then
                let tokenOpt := getSessionFromHeaders req.headers
                if tokenOpt.isNone then unauthResponse
                else
                  let token := tokenOpt.get!
                  match findSession oldState.state token with
                  | none => unauthResponse
                  | some userId =>
                    match findUserById oldState.state userId with
                    | none => unauthResponse
                    | some user =>
                      let oldP := extractJsonField req.body "old_password"
                      let newP := extractJsonField req.body "new_password"
                      if oldP.isNone || newP.isNone then jsonError "400 Bad Request" "Missing fields"
                      else
                        let op := oldP.get!
                        let np := newP.get!
                        if user.password != op then jsonError "401 Unauthorized" "Invalid credentials"
                        else if not (validatePassword np) then jsonError "400 Bad Request" "Password too short"
                        else
                          let updatedUser := { user with password := np }
                          let newUsers := oldState.state.users.map (fun us => if us.id == userId then updatedUser else us)
                          stateRef.set { oldState with state := { oldState.state with users := newUsers } }
                          jsonOk "{}"
              else if req.method == "GET" && req.path == "/todos" then
                let tokenOpt := getSessionFromHeaders req.headers
                if tokenOpt.isNone then unauthResponse
                else
                  let token := tokenOpt.get!
                  match findSession oldState.state token with
                  | none => unauthResponse
                  | some userId =>
                    let userTodos := oldState.state.todos.filter (fun t => t.userId == userId)
                    let sorted := userTodos.mergeSort (fun a b => a.id < b.id)
                    let arr := sorted.map todoToJson
                    jsonOk (toJsonArray arr)
              else if req.method == "POST" && req.path == "/todos" then
                let tokenOpt := getSessionFromHeaders req.headers
                if tokenOpt.isNone then unauthResponse
                else
                  let token := tokenOpt.get!
                  match findSession oldState.state token with
                  | none => unauthResponse
                  | some userId =>
                    let titleOpt := extractJsonField req.body "title"
                    if titleOpt.isNone || titleOpt.get! == "" then jsonError "400 Bad Request" "Title is required"
                    else
                      let title := titleOpt.get!
                      let descOpt := extractJsonField req.body "description"
                      let desc := Option.getD descOpt ""
                      let time ← getCurrentTime
                      let newTodo := { id := oldState.state.nextTodoId, userId, title, description := desc, completed := false, createdAt := time, updatedAt := time }
                      stateRef.set { oldState with state := { oldState.state with todos := oldState.state.todos ++ [newTodo], nextTodoId := oldState.state.nextTodoId + 1 } }
                      jsonCreated (todoToJson newTodo)
              else if req.path.startsWith "/todos/" then
                let rest := req.path.drop "/todos/".length
                let tokenOpt := getSessionFromHeaders req.headers
                if tokenOpt.isNone then unauthResponse
                else
                  let token := tokenOpt.get!
                  match findSession oldState.state token with
                  | none => unauthResponse
                  | some userId =>
                    match rest.toNat? with
                    | none => notFoundResponse
                    | some id =>
                      let todoOpt := oldState.state.todos.find? (fun t => t.id == id && t.userId == userId)
                      if req.method == "GET" then
                        match todoOpt with
                        | none => notFoundResponse
                        | some todo => jsonOk (todoToJson todo)
                      else if req.method == "PUT" then
                        match todoOpt with
                        | none => notFoundResponse
                        | some oldTodo =>
                          let titleOpt := extractJsonField req.body "title"
                          if titleOpt.map (fun t => t == "") |>.getD false then jsonError "400 Bad Request" "Title is required"
                          else
                            let newTitle := Option.getD titleOpt oldTodo.title
                            let descOpt := extractJsonField req.body "description"
                            let newDesc := Option.getD descOpt oldTodo.description
                            let compOpt := extractJsonBool req.body "completed"
                            let newComp := compOpt.getD oldTodo.completed
                            let time ← getCurrentTime
                            let updated := { oldTodo with title := newTitle, description := newDesc, completed := newComp, updatedAt := time }
                            let idx := listFindIdx? (fun t => t.id == id) oldState.state.todos |>.get!
                            let newTodos := listSet oldState.state.todos idx updated
                            stateRef.set { oldState with state := { oldState.state with todos := newTodos } }
                            jsonOk (todoToJson updated)
                      else if req.method == "DELETE" then
                        match todoOpt with
                        | none => notFoundResponse
                        | some _ =>
                          let idx := listFindIdx? (fun t => t.id == id) oldState.state.todos |>.get!
                          let newTodos := listEraseIdx oldState.state.todos idx
                          stateRef.set { oldState with state := { oldState.state with todos := newTodos } }
                          buildResponse "204 No Content" [] none
                      else notFoundResponse
              else
                jsonError "404 Not Found" "Not found"
            
            let respStr := serializeResponse resp
            let chunk := stringToByteArray respStr
            let _ ← client.sendAll #[chunk]
            discard <| client.shutdown
          | none =>
            let err := serializeResponse (jsonError "400 Bad Request" "Invalid request")
            let chunk := stringToByteArray err
            let _ ← client.sendAll #[chunk]
            discard <| client.shutdown
        else
          discard <| client.shutdown
      else
        discard <| client.shutdown
    | _ => 
      IO.sleep 10
    loop
  
  loop
  pure 0
