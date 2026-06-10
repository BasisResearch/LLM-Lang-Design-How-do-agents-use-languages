import TodoApp.Types
import Init.System.IO
import Init.Data.ToString

namespace TodoApp

/-- Generate current timestamp in ISO 8601 format YYYY-MM-DDTHH:MM:SSZ -/
def getCurrentTimestamp : IO String := do
  let proc ← IO.Process.run { 
    cmd := "date", 
    args := #["-u", "+%Y-%m-%dT%H:%M:%SZ"] 
  }
  -- Return the date string as is for now
  return proc

/-- Validate username format: 3-50 chars, alphanumeric and underscore only -/
def isValidUsername (username : String) : Bool :=
  let len := username.length 
  len ≥ 3 ∧ len ≤ 50 ∧ 
  username.all fun c => c.isAlphanum ∨ c == '_'

/-- Validate password length -/
def isValidPassword (password : String) : Bool :=
  password.length ≥ 8

end TodoApp