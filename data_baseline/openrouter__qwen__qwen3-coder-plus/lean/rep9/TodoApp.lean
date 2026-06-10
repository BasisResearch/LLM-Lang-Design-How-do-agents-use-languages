/-
Todo App REST API Server 
Implementation with cookie-based authentication
-/

import Batteries.Data.HashMap
open Batteries (HashMap)

-- Import additional utilities  
abbrev Nat := Nat
abbrev String := String
abbrev Bool := Bool

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
  users := {},  -- Empty HashMap  
  todos := {}, 
  sessions := {},
  nextUserId := 1,
  nextTodoId := 1
}

/--
Validate username according to spec
-/
def validateUsername (username : String) : Bool := 
  let len := username.length
  if len < 3 || len > 50 then 
    false
  else
    username.all fun c => c.isAlphanum || c == '_'

/--
Validate password minimum length
-/
def validatePassword (password : String) : Bool := 
  password.length >= 8

/--
Core functionality implementation
-/

def authenticateUser (state: AppState) (session_id : String) : Option UserId := 
  state.sessions[session_id]?

def getUserById (state : AppState) (user_id : UserId) : Option User := 
  let userList := state.users.toArray
  let userMaybe := Array.find? userList (fun p => p.2.id == user_id) 
  match userMaybe with
  | some (_, user) => some user
  | none => none

def getTodosByUserId (state : AppState) (user_id : UserId) : Array Todo := 
  let todosArray := state.todos.toArray
  let userTodos := todosArray.filter (fun p => p.2.userId == user_id) |>.map (fun p => p.2)
  -- Sort by id in ascending order
  userTodos.qsort (· < ·) (fun t => t.id)

def registerNewUser (state : AppState) (username : String) (password : String) : 
   Sum String (AppState × User) := 
  if ¬(validateUsername username) then
    Sum.inl "Invalid username"
  else if ¬(validatePassword password) then
    Sum.inl "Password too short"
  else if state.users.contains username then
    Sum.inl "Username already exists"
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
    Sum.inr (newState, newUser)

def authenticateCredentials (state : AppState) (username : String) (password : String) : 
    Option (User × SessionId) := 
  let userMaybe := state.users[username]?
  match userMaybe with
  | some user => 
    -- Simplified password check, real impl would hash the password and compare
    if password == user.passwordHash then 
      let sessionId := s!"sess_{password}_{username}" -- Very simplified ID generation 
      some (user, sessionId)
    else none
  | none => none

def createNewSession (state : AppState) (user_id : UserId) (session_id : SessionId) : AppState :=
  {state with sessions := state.sessions.insert session_id user_id}

def removeSession (state : AppState) (session_id : SessionId) : AppState :=
  {state with sessions := state.sessions.erase session_id}

def createTodo (state : AppState) (user_id : UserId) (title : String) (description : String) :
   (AppState × Todo) := 
  let timestamp := "2025-01-15T09:30:00Z"  -- Simplified timestamp
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
  let todoMaybe := state.todos[todo_id]?
  match todoMaybe with
  | some todo => if todo.userId == user_id then some todo else none
  | none => none

def updateTodoFields (state : AppState) (todo_id : TodoId) (user_id : UserId) 
    (new_title : Option String) (new_description : Option String) (new_completed : Option Bool) : 
    Option (AppState × Todo) :=
  let old_todo? := getTodoById state todo_id user_id
  match old_todo? with
  | some old_todo =>
      let new_title_val := match new_title with | some t => t | none => old_todo.title
      if new_title_val.length == 0 then 
        none  -- Title cannot be empty
      else
        let new_description_val := match new_description with | some d => d | none => old_todo.description
        let new_completed_val := match new_completed with | some c => c | none => old_todo.completed
        let timestamp := "2025-01-15T09:30:01Z"  -- Updated timestamp
        let updated_todo := { old_todo with 
          title := new_title_val,
          description := new_description_val,
          completed := new_completed_val,
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
  let userArray := state.users.toArray
  let userMaybe := Array.find? userArray (fun (_uname, u) => u.id == user_id)
  match userMaybe with 
  | some (uname, user) => 
    if user.passwordHash == oldPassword ∧ newPassword.length ≥ 8 then
      let new_user := { user with passwordHash := newPassword }
      let new_users := state.users.insert uname new_user
      let new_state := { state with users := new_users }
      some (new_state, new_user)
    else 
      none
  | none => none

end TodoApp