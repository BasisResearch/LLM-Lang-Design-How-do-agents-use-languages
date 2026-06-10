namespace TodoApp

/-- User type representing a user in the system -/
structure User where
  /-- Unique identifier for the user, auto-incrementing starting from 1 -/
  id : Nat
  /-- Username, should be unique among all users -/
  username : String
  /-- Hashed password -/
  passwordHash : String
  deriving Repr

/-- Todo type representing a task -/
structure Todo where
  /-- Unique identifier for the todo, auto-incrementing starting from 1 -/
  id : Nat
  /-- The title of the todo item -/
  title : String
  /-- Optional description explaining the todo in more detail -/
  description : String := ""
  /-- Whether the task has been completed -/
  completed : Bool := false
  /-- Timestamp when the todo was created (ISO 8601 format) -/
  createdAt : String 
  /-- Timestamp when the todo was last updated (ISO 8601 format) -/
  updatedAt : String
  /-- ID of the user who owns this todo -/
  userId : Nat
  deriving Repr
  
/-- Error response structure -/
structure ErrorResponse where
  error : String
  deriving Repr

end TodoApp  