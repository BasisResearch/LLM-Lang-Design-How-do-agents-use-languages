/- Todo App Data Types -/
def Timestamp := String
def SessionId := String
def UserId := Nat
def TodoId := Nat

structure User where
  id : UserId
  username : String
  passwordHash : String  -- In a real app, this would be a proper hash
deriving Repr

structure Todo where
  id : TodoId
  title : String
  description : String
  completed : Bool
  createdAt : Timestamp
  updatedAt : Timestamp
deriving Repr

structure RegisterReq where
  username : String
  password : String

structure LoginReq where
  username : String
  password : String

structure ChangePasswordReq where
  old_password : String
  new_password : String

structure CreateTodoReq where
  title : String
  description : String  -- Optional, defaults to ""

structure UpdateTodoReq where
  title : Option String
  description : Option String
  completed : Option Bool

structure ErrorResp where
  error : String

def currentTimeIso8601 : IO Timestamp := do
  -- Simple current time implementation - in practice should use proper timestamp functionality
  return "2025-01-15T09:30:00Z"