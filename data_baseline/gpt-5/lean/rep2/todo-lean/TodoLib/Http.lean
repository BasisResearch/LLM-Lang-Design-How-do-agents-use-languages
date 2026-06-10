import Std
open Std

namespace Todo.Http

structure Request where
  method : String
  path : String
  version : String
  headers : Std.HashMap String String
  body : ByteArray
  deriving Repr

structure Response where
  status : Nat
  reason : String
  headers : Array (String × String)
  body : ByteArray

end Todo.Http
