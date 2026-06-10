namespace TodoApp

structure HttpResponse where
  statusCode : Nat
  headers : List (String × String)
  body : String
  deriving Repr

structure HttpRequest where
  method : String
  url : String
  headers : List (String × String)
  body : String
  deriving Repr

-- Standard response utility functions
def jsonResponse (obj : String) (statusCode := 200): HttpResponse :=
  { statusCode := statusCode,
    headers := [("Content-Type", "application/json"), ("Access-Control-Allow-Origin", "*")],
    body := obj }

def getCookieValue (headers : List (String × String)) (cookieName : String) : Option String :=
  match headers.find? (fun (name, _) => name == "Cookie") with
  | some (_, cookieHeader) => 
    let cookies := cookieHeader.splitOn "; "
    let sessionCookie := cookies.find? (fun cookie => cookie.startsWith (cookieName ++ "="))
    match sessionCookie with
    | some sc => 
      let parts := sc.splitOn "="
      if parts.size = 2 then
        let value := parts.getD 1 ""
        some value
      else
        none
    | none => 
      none
  | none => 
    none

def mkSetCookieHeader (cookieName : String) (cookieValue : String) : String × String := 
  ( "Set-Cookie", 
    cookieName ++ "=" ++ cookieValue ++ "; Path=/; HttpOnly" )

end TodoApp