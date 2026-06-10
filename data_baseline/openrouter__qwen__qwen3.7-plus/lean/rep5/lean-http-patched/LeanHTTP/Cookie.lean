import LeanHTTP.Types

namespace LeanHTTP

structure CookieOptions where
  path : Option String := some "/"
  domain : Option String := none
  maxAge : Option Nat := none
  secure : Bool := false
  httpOnly : Bool := false
  sameSite : Option String := none  -- "Strict", "Lax", "None"

/-- Parse Cookie header value "name1=value1; name2=value2" and find a cookie by name -/
def HttpRequest.cookie (req : HttpRequest) (name : String) : Option String :=
  -- Find Cookie header (case-insensitive)
  match req.headers.find? (fun (k, _) => k.toLower == "cookie") with
  | none => none
  | some (_, cookieHeader) =>
    -- Split by "; " then by "=" to find matching name
    let pairs := cookieHeader.splitOn "; "
    let found := pairs.find? fun pair =>
      match pair.splitOn "=" with
      | k :: _ => k.trimAscii.toString == name
      | _ => false
    match found with
    | none => none
    | some pair =>
      match pair.splitOn "=" with
      | _ :: rest => some ("=".intercalate rest)
      | _ => none

/-- Build Set-Cookie header string and add it to the response -/
def HttpResponse.setCookie (resp : HttpResponse) (name value : String)
    (opts : CookieOptions := {}) : HttpResponse :=
  let base := s!"{name}={value}"
  let parts := #[base]
  let parts := match opts.path with
    | some p => parts.push s!"Path={p}"
    | none => parts
  let parts := match opts.domain with
    | some d => parts.push s!"Domain={d}"
    | none => parts
  let parts := match opts.maxAge with
    | some a => parts.push s!"Max-Age={a}"
    | none => parts
  let parts := if opts.secure then parts.push "Secure" else parts
  let parts := if opts.httpOnly then parts.push "HttpOnly" else parts
  let parts := match opts.sameSite with
    | some s => parts.push s!"SameSite={s}"
    | none => parts
  let headerValue := "; ".intercalate parts.toList
  { resp with headers := resp.headers.push ("Set-Cookie", headerValue) }

end LeanHTTP
