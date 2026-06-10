import TodoApp.Types
import TodoApp.Utilities
import Std.Data.HashMap

namespace TodoApp

-- Simple state storage - for in-memory only
structure ServerState where
  users : HashMap Nat User := {}
  todos : HashMap Nat Todo := {}
  sessions : HashMap String Nat := {}  -- session_id -> user_id
  nextUserId : Nat := 1
  nextTodoId : Nat := 1
  deriving Repr

-- Create initial state
def emptyState : ServerState := {}

-- Helper functions for accessing state
def addUser (state : ServerState) (username : String) (passwordHash : String) : User × ServerState :=
  let user := { id := state.nextUserId, username := username, passwordHash := passwordHash }
  let newUserMap := state.users.insert user.id user
  let newState := { state with 
    users := newUserMap,
    nextUserId := state.nextUserId + 1
  }
  (user, newState)

def findUserByUsername (state : ServerState) (username : String) : Option User :=
  let usersArray := state.users.toArray
  usersArray.find? (fun (_, u) => u.username == username) |>.map (·.snd)

def getSessionUserId (state : ServerState) (sessionId : String) : Option Nat :=
  state.sessions.find? sessionId

def authenticateSession (state : ServerState) (sessionId : String) : Option User :=
  match state.getSessionUserId sessionId with
  | some userId => state.users.find? userId
  | none => none

def addSession (state : ServerState) (userId : Nat) : String × ServerState := 
  let sessionId ← TodoApp.generateSessionId
  let newSessionsMap := state.sessions.insert sessionId userId
  (sessionId, { state with sessions := newSessionsMap })

def invalidateSession (state : ServerState) (sessionId : String) : ServerState :=
  { state with sessions := state.sessions.erase sessionId }

def addTodo (state : ServerState) (userId : Nat) (title : String) (description : String) : Todo × ServerState := 
  let createdAt ← TodoApp.getCurrentTimestamp
  let updatedAt := createdAt
  let todo := { 
    id := state.nextTodoId, 
    title := title, 
    description := description, 
    completed := false, 
    createdAt := createdAt, 
    updatedAt := updatedAt,
    userId := userId
  }
  let newTodosMap := state.todos.insert todo.id todo
  let newState := { state with 
    todos := newTodosMap, 
    nextTodoId := state.nextTodoId + 1
  }
  (todo, newState)

def getUserTodos (state : ServerState) (userId : Nat) : Array Todo :=
  state.todos.toArray.foldl (init := #[]) fun acc (key, todo) =>
    if todo.userId == userId then acc.push todo else acc

def getTodoById (state : ServerState) (todoId : Nat) (userId : Nat) : Option Todo :=
  match state.todos.find? todoId with
  | some todo => if todo.userId == userId then some todo else none
  | none => none

def removeTodoById (state : ServerState) (todoId : Nat) : ServerState :=
  { state with todos := state.todos.erase todoId }

def updateTodoById (state : ServerState) (todoId : Nat) 
    (title : Option String) (description : Option String) (completed : Option Bool) : Option (Todo × ServerState) := 
  match state.todos.find? todoId with
  | some todo => 
    -- Only update if user owns this todo
    let newTitle := match title with | some t => t | none => todo.title
    let newDescription := match description with | some d => d | none => todo.description
    let newCompleted := match completed with | some c => c | none => todo.completed
    
    let updatedAt ← TodoApp.getCurrentTimestamp
    let updatedTodo := { 
      todo with 
        title := newTitle, 
        description := newDescription, 
        completed := newCompleted, 
        updatedAt := updatedAt 
    }
    
    let newTodosMap := state.todos.insert todoId updatedTodo
    let newState := { state with todos := newTodosMap }
    some (updatedTodo, newState)
  | none => 
    none

end TodoApp