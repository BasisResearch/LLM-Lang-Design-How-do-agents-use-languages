/-
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