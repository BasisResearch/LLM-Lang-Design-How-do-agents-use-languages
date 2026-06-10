/-
Todo App REST API Server
Implementation with cookie-based authentication
-/

import Batteries.Data.HashMap
open Batteries (HashMap)

namespace TodoApp

/--
Data structure for representing a User
-/
structure User where
  id : Nat
  username : String
  passwordHash : String  -- In real applications, hash passwords
deriving Repr

/--
Data structure for representing a Todo
-/
structure Todo where
  id : Nat  
  title : String
  description : String
  completed : Bool
  createdAt : String
  updatedAt : String
  userId : Nat  -- The user who owns this todo
deriving Repr

/--
Application state keeping track of users, todos, and sessions
-/
abbrev UserId := Nat
abbrev SessionId := String
abbrev Username := String
abbrev TodoId := Nat

structure AppState where
  users : HashMap Username User  -- Map from usernames to users
  todos : HashMap TodoId Todo    -- Map from todo IDs to todo objects
  sessions : HashMap SessionId UserId  -- Map from session IDs to user IDs
  nextUserId : Nat
  nextTodoId : Nat

/--
Initial application state
-/
def initAppState : AppState := {
  users := ∅,  -- Empty HashMap notation
  todos := ∅, 
  sessions := ∅,
  nextUserId := 1,
  nextTodoId := 1
}

/--
Timestamp generation for Created At/Updated At fields.
Returns a basic string representation of current timestamp
-/
def getCurrentTimestamp : IO String := do
  let now ← IO.monoMsNow
  return s!"{now}Z"  -- Basic timestamp placeholder

/--
Generate a random session ID for authentication cookies.
-/
def makeSessionId : IO String := do
  let randVal ← IO.rand 1000000 9999999
  return toString randVal

/--
Validate username according to spec
-/
def validateUsername (username : String) : Bool := 
  let len := username.length
  if len < 3 || len > 50 then false
  else
    username.all fun c => c.isAlphanum || c == '_'

/--
Validate password minimum length
-/
def validatePassword (password : String) : Bool := 
  password.length >= 8

end TodoApp/-
Separate module for implementing business logic that the python server can call
-/

import Batteries.Data.HashMap
open Batteries (HashMap)

namespace TodoApp

/-
Core functionality that gets used by the business logic 
-/

def authenticateUser (state: AppState) (session_id : String) : Option UserId := 
  state.sessions.get? session_id

def getUserById (state : AppState) (user_id : UserId) : Option User := 
  let user_list := state.users.toList
  user_list.find? (fun p => p.snd.id == user_id)

def getTodosByUserId (state : AppState) (user_id : UserId) : Array Todo := 
  let all_todos := state.todos.toArray
  let user_todos := Array.filter all_todos (·.val.userId == user_id) |>.map (·.val)
  user_todos.qsort (·.id < ·.id)

def getAllUsers (state : AppState) : Array User := 
  let arr := state.users.toArray 
  arr.map (·.snd)

def registerNewUser (state : AppState) (username : String) (password : String) : 
   Either String (AppState × User) := 
  if !validateUsername username then
    .left "Invalid username"
  else if !validatePassword password then
    .left "Password too short"
  else if state.users.contains username then
    .left "Username already exists"
  else
    let passwordHash := password  -- Simplified for example, would hash in real impl
    let newUser : User := {
      id := state.nextUserId,
      username := username,
      passwordHash := passwordHash
    }
    let newUsers := state.users.insert username newUser
    let newState := {
      state with
      users := newUsers,
      nextUserId := state.nextUserId + 1
    }
    .right (newState, newUser)

def authenticateCredentials (state : AppState) (username : String) (password : String) : 
    Option (User × SessionId) := 
  match state.users.get? username with
  | some user => 
    -- Simplified password check, real impl would hash the password and compare
    if password == user.passwordHash then 
      let session_id ← unsafe ioAsTask (makeSessionId)
      some (user, session_id)
    else none
  | none => none

def createNewSession (state : AppState) (user_id : UserId) (session_id : SessionId) : AppState :=
  {state with sessions := state.sessions.insert session_id user_id}

def removeSession (state : AppState) (session_id : SessionId) : AppState :=
  {state with sessions := state.sessions.erase session_id}

def createTodo (state : AppState) (user_id : UserId) (title : String) (description : String) :
   (AppState × Todo) := 
  let timestamp ← unsafe ioAsTask (getCurrentTimestamp)
  let newTodo : Todo := {
    id := state.nextTodoId,
    title := title,
    description := description,
    completed := false,
    createdAt := timestamp,
    updatedAt := timestamp,
    userId := user_id
  }
  let newTodos := state.todos.insert newTodo.id newTodo
  let newState := {state with 
    todos := newTodos,
    nextTodoId := state.nextTodoId + 1
  }
  (newState, newTodo)

def getTodoById (state : AppState) (todo_id : TodoId) (user_id : UserId) : Option Todo :=
  match state.todos.get? todo_id with
  | some todo => if todo.userId == user_id then some todo else none
  | none => none

def updateTodoTitle (state : AppState) (todo_id : TodoId) (user_id : UserId) (new_title : String) : 
   Option (AppState × Todo) :=
  let old_todo? := getTodoById state todo_id user_id
  match old_todo? with
  | some old_todo =>
    if new_title.length == 0 then none  -- Title cannot be empty
    else
      let timestamp ← unsafe ioAsTask (getCurrentTimestamp)
      let updated_todo := { old_todo with 
        title := new_title,
        updatedAt := timestamp
      }
      let new_todos := state.todos.insert todo_id updated_todo
      let new_state := { state with todos := new_todos }
      some (new_state, updated_todo)
  | none => none

def updateTodoDescription (state : AppState) (todo_id : TodoId) (user_id : UserId) (new_description : String) : 
   Option (AppState × Todo) :=
  let old_todo? := getTodoById state todo_id user_id
  match old_todo? with
  | some old_todo =>
      let timestamp ← unsafe ioAsTask (getCurrentTimestamp)
      let updated_todo := { old_todo with 
        description := new_description,
        updatedAt := timestamp
      }
      let new_todos := state.todos.insert todo_id updated_todo
      let new_state := { state with todos := new_todos }
      some (new_state, updated_todo)
  | none => none

def updateTodoCompleted (state : AppState) (todo_id : TodoId) (user_id : UserId) (new_completed : Bool) : 
   Option (AppState × Todo) :=
  let old_todo? := getTodoById state todo_id user_id
  match old_todo? with
  | some old_todo =>
      let timestamp ← unsafe ioAsTask (getCurrentTimestamp)
      let updated_todo := { old_todo with 
        completed := new_completed,
        updatedAt := timestamp
      }
      let new_todos := state.todos.insert todo_id updated_todo
      let new_state := { state with todos := new_todos }
      some (new_state, updated_todo)
  | none => none

def deleteTodo (state : AppState) (todo_id : TodoId) (user_id : UserId) : Option AppState :=
  let old_todo? := getTodoById state todo_id user_id
  match old_todo? with
  | some _old_todo =>
      let new_todos := state.todos.erase todo_id
      let new_state := { state with todos := new_todos }
      some new_state
  | none => none

def changePassword (state : AppState) (user_id : UserId) (oldPassword : String) (newPassword : String) :
    Option (AppState × User) :=
  let user_maybe := getAllUsers state |>.find? (·.id == user_id)
  match user_maybe with 
  | some user => 
    if user.passwordHash == oldPassword ∧ newPassword.length ≥ 8 then
      let new_user := { user with passwordHash := newPassword }
      let new_users := state.users.insert user.username new_user
      let new_state := { state with users := new_users }
      some (new_state, new_user)
    else none
  | none => none

end TodoApp