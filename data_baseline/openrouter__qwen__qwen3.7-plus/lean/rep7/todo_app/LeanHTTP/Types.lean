import Std.Data.HashMap

namespace LeanHTTP

inductive HttpMethod where
  | GET | POST | PUT | DELETE | PATCH | HEAD | OPTIONS
  deriving BEq, Repr

instance : ToString HttpMethod where
  toString
    | .GET => "GET"
    | .POST => "POST"
    | .PUT => "PUT"
    | .DELETE => "DELETE"
    | .PATCH => "PATCH"
    | .HEAD => "HEAD"
    | .OPTIONS => "OPTIONS"

structure HttpRequest where
  method : HttpMethod
  path : String
  headers : Array (String × String)
  body : ByteArray
  params : Std.HashMap String String   -- URL params like {id}
  query : Std.HashMap String String    -- Query params like ?key=val
  context : Std.HashMap String String := {}  -- Middleware context for request-scoped data

structure HttpResponse where
  status : Nat
  statusText : String
  headers : Array (String × String)
  body : ByteArray

def Handler := HttpRequest → IO HttpResponse

def Middleware := Handler → Handler

end LeanHTTP
