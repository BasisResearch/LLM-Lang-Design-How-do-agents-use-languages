/- Utility functions for the Todo app -/

-- Basic JSON formatting functions
def jsonString (s : String) := "\"" ++ s.replace "\"" "\\\""  ++ "\""

def jsonNumber (n : Nat) := toString n

def jsonBool (b : Bool) := if b then "true" else "false"

def jsonObject (fields : List (String × String)) : String :=
  "{" ++ (fields.map (fun (k, v) => jsonString k ++ ":" ++ v)).intersperse "," ++ "}"

def jsonArray (items : List String) : String :=
  "[" ++ items.intersperse "," ++ "]"

def escapeStr (s : String) : String := 
  s.replace "\"" "\\\""

def toSimpleJsonString {α} (a : α) : String := 
  jsonString (toString a)

-- Basic JSON value type (simplified)
inductive SimpleJson where
  | str (s : String)
  | num (n : Int)
  | bool (b : Bool)
  | null
  | obj (fields : List (String × SimpleJson))
  | arr (elems : List SimpleJson)
deriving Repr

-- Manually convert User to JSON string
def encodeUser (user : User) : String :=
  let fields : List (String × String) := 
    [ ("id", jsonNumber user.id),
      ("username", jsonString user.username) ]
  "{" ++ (fields.map (fun (k, v) => jsonString k ++ ":" ++ v)).intersperse "," ++ "}"

-- Manually convert Todo to JSON string
def encodeTodo (todo : Todo) : String :=
  let fields : List (String × String) := 
    [ ("id", jsonNumber todo.id),
      ("title", jsonString todo.title),
      ("description", jsonString todo.description),
      ("completed", jsonBool todo.completed),
      ("created_at", jsonString todo.createdAt),
      ("updated_at", jsonString todo.updatedAt) ]
  "{" ++ (fields.map (fun (k, v) => jsonString k ++ ":" ++ v)).intersperse "," ++ "}"

-- Manually convert ErrorResp to JSON string
def encodeErrorResp (err : ErrorResp) : String :=
  let fields : List (String × String) := 
    [ ("error", jsonString err.error) ]
  "{" ++ (fields.map (fun (k, v) => jsonString k ++ ":" ++ v)).intersperse "," ++ "}"

def encodeTodoList (todos : List Todo) : String :=
  "[" ++ (todos.map encodeTodo).intersperse "," ++ "]"

-- Minimal JSON field extraction function (simplified parser)
def extractJsonStringField (jsonStr : String) (field : String) : Option String := 
  -- This is a very basic JSON parser that looks for "field":"value" pattern
  let patternStart := "\"" ++ field ++ "\":\""
  let startPos := jsonStr.findSubstr? patternStart
  match startPos with
  | .none => .none
  | .some s =>
    let remaining := jsonStr.extract s (jsonStr.length)
    let quote1Idx := remaining.find? (· == '"')
    match quote1Idx with
    | .none => .none
    | .some startIdx =>
      let afterFirstQuote := remaining.extract (startIdx + 1) remaining.length
      let quote2Idx := afterFirstQuote.find? (· == '"')
      match quote2Idx with
      | .none => remaining.extract (startIdx + 1) afterFirstQuote.length
      | .some endIdx => remaining.extract (startIdx + 1) (startIdx + 1 + endIdx)

def extractJsonNumberField (jsonStr : String) (field : String) : Option Nat := 
  -- This is a basic JSON parser looking for "field":number pattern
  let patternStart := "\"" ++ field ++ "\":"
  let startPos := jsonStr.findSubstr? patternStart
  match startPos with
  | .none => .none
  | .some s =>
    let remaining := jsonStr.extract s (jsonStr.length)
    -- Skip past the colon
    let afterColon := remaining.extract patternStart.length remaining.length
    -- Now extract number
    let numStart := afterColon.find? (fun c => c.isDigit || c == '-')
    match numStart with
    | .none => .none
    | .some idx =>
      let nums := afterColon.extract idx afterColon.length
      let digitsEndIdx := nums.findIdxOrEnd (· != ',' ∧ · != '}' ∧ · != ']')
      match (nums.extract 0 digitsEndIdx).toNat? with
      | .none => .none
      | .some n => .some n

def decodeRegisterReq (jsonStr : String) : Option RegisterReq := 
  let username? := extractJsonStringField jsonStr "username"
  let password? := extractJsonStringField jsonStr "password"
  match username?, password? with
  | .some u, .some p => .some { username := u, password := p }
  | _, _ => .none

def decodeLoginReq (jsonStr : String) : Option LoginReq := 
  let username? := extractJsonStringField jsonStr "username"
  let password? := extractJsonStringField jsonStr "password"
  match username?, password? with
  | .some u, .some p => .some { username := u, password := p }
  | _, _ => .none

def decodeChangePasswordReq (jsonStr : String) : Option ChangePasswordReq := 
  let old_password? := extractJsonStringField jsonStr "old_password"
  let new_password? := extractJsonStringField jsonStr "new_password"
  match old_password?, new_password? with
  | .some oldpw, .some newpw => .some { old_password := oldpw, new_password := newpw }
  | _, _ => .none

def decodeCreateTodoReq (jsonStr : String) : Option CreateTodoReq := 
  let title? := extractJsonStringField jsonStr "title"
  let description? := extractJsonStringField jsonStr "description"
  match title? with
  | .some t => .some { title := t, description := description?.getD "" }
  | .none => .none

def decodeUpdateTodoReq (jsonStr : String) : Option UpdateTodoReq := 
  let title? := extractJsonStringField jsonStr "title"
  let description? := extractJsonStringField jsonStr "description"  
  let completed? := 
    let patternStart := "\"completed\":"
    match jsonStr.findSubstr? patternStart with
    | .none => .none
    | .some s =>
      let remaining := jsonStr.extract s jsonStr.length
      let afterColon := remaining.extract patternStart.length remaining.length
      if afterColon.startsWith "true" then .some true
      else if afterColon.startsWith "false" then .some false
      else .none
  
  -- At least one field might exist
  .some {
    title := title?,
    description := description?,
    completed := completed?
  }

/- Helper for updating storage references -/