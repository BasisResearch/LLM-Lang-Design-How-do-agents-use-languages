import LeanHTTP.Types

namespace LeanHTTP

def HttpRequest.param (req : HttpRequest) (name : String) : Option String :=
  req.params[name]?

def HttpRequest.paramNat (req : HttpRequest) (name : String) : Option Nat :=
  match req.params[name]? with
  | some s => s.toNat?
  | none => none

def HttpRequest.queryParam (req : HttpRequest) (name : String) : Option String :=
  req.query[name]?

/-- Get a value from middleware context -/
def HttpRequest.ctx (req : HttpRequest) (key : String) : Option String :=
  req.context[key]?

/-- Set a value in middleware context, returning new request -/
def HttpRequest.withCtx (req : HttpRequest) (key value : String) : HttpRequest :=
  { req with context := req.context.insert key value }

def HttpRequest.header (req : HttpRequest) (name : String) : Option String :=
  match req.headers.find? (fun (k, _) => k.toLower == name.toLower) with
  | some (_, v) => some v
  | none => none

def HttpRequest.contentType (req : HttpRequest) : Option String :=
  req.header "content-type"

def HttpRequest.userAgent (req : HttpRequest) : Option String :=
  req.header "user-agent"

end LeanHTTP
