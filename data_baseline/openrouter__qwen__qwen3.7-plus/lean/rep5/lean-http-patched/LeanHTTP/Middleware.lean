import LeanHTTP.Types
import LeanHTTP.Response

namespace LeanHTTP

def loggerMiddleware : Middleware := fun next req => do
  let start ← IO.monoNanosNow
  let response ← next req
  let elapsed ← IO.monoNanosNow
  let ms := (elapsed - start) / 1000000
  IO.println s!"{req.method} {req.path} {response.status} {ms}ms"
  return response

def recovererMiddleware : Middleware := fun next req => do
  try
    next req
  catch e =>
    IO.eprintln s!"Panic recovered: {e}"
    return HttpResponse.internalServerError (toString e)

/-- CORS configuration -/
structure CorsConfig where
  allowedOrigins : Array String := #["*"]
  allowedMethods : Array String := #["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"]
  allowedHeaders : Array String := #["Content-Type", "Authorization"]
  allowCredentials : Bool := false
  maxAge : Nat := 86400

private def addCorsHeaders (resp : HttpResponse) (config : CorsConfig) (origin : Option String) : HttpResponse :=
  let allowOrigin := if config.allowedOrigins.contains "*" then "*"
    else match origin with
      | some o => if config.allowedOrigins.contains o then o else ""
      | none => ""
  if allowOrigin == "" then resp
  else
    let h := resp.headers.push ("Access-Control-Allow-Origin", allowOrigin)
    let h := if config.allowCredentials then h.push ("Access-Control-Allow-Credentials", "true") else h
    { resp with headers := h }

def corsMiddleware (config : CorsConfig := {}) : Middleware := fun next req => do
  let origin := (req.headers.find? (fun (k, _) => k.toLower == "origin")).map (·.2)
  if req.method == .OPTIONS then
    -- Preflight request
    let methods := ", ".intercalate config.allowedMethods.toList
    let headers := ", ".intercalate config.allowedHeaders.toList
    let resp : HttpResponse := {
      status := 204
      statusText := "No Content"
      headers := #[
        ("Access-Control-Allow-Methods", methods),
        ("Access-Control-Allow-Headers", headers),
        ("Access-Control-Max-Age", toString config.maxAge)
      ]
      body := ByteArray.empty
    }
    return addCorsHeaders resp config origin
  else
    let resp ← next req
    return addCorsHeaders resp config origin

def requestIdMiddleware : Middleware := fun next req => do
  let existingId := (req.headers.find? (fun (k, _) => k.toLower == "x-request-id")).map (·.2)
  let reqId ← match existingId with
    | some id => pure id
    | none => do
      let nanos ← IO.monoNanosNow
      pure s!"req-{nanos}"
  let resp ← next req
  return { resp with headers := resp.headers.push ("X-Request-Id", reqId) }

/-- Rate limiter configuration -/
structure RateLimitConfig where
  maxRequests : Nat := 100
  windowMs : Nat := 60000

/-- Rate limiter state -/
structure RateLimiterState where
  count : Nat
  windowStart : Nat

/-- Create a rate limiting middleware. Returns IO Middleware because it needs IO.Ref for state. -/
def rateLimitMiddleware (config : RateLimitConfig := {}) : IO Middleware := do
  let state ← IO.mkRef ({ count := 0, windowStart := 0 } : RateLimiterState)
  return fun next req => do
    let now ← IO.monoNanosNow
    let windowNs := config.windowMs * 1000000
    let st ← state.get
    let st := if now - st.windowStart >= windowNs then
      { count := 0, windowStart := now }
    else st
    if st.count >= config.maxRequests then
      return { status := 429, statusText := "Too Many Requests",
               headers := #[("Content-Type", "text/plain"),
                            ("Retry-After", toString (config.windowMs / 1000)),
                            ("Content-Length", toString "Too Many Requests".utf8ByteSize)],
               body := "Too Many Requests".toUTF8 }
    else
      state.set { st with count := st.count + 1 }
      next req

/-- Timeout middleware: returns 504 Gateway Timeout if handler takes too long -/
def timeoutMiddleware (timeoutMs : Nat := 30000) : Middleware := fun next req => do
  let resultRef ← IO.mkRef (none : Option HttpResponse)
  let _ ← IO.asTask do
    let resp ← next req
    resultRef.set (some resp)
  let startTime ← IO.monoNanosNow
  let timeoutNs := timeoutMs * 1000000
  for _ in [:timeoutMs / 10] do
    match ← resultRef.get with
    | some resp => return resp
    | none =>
      let now ← IO.monoNanosNow
      if now - startTime >= timeoutNs then
        return { status := 504, statusText := "Gateway Timeout",
                 headers := #[("Content-Type", "text/plain"),
                              ("Content-Length", toString "Gateway Timeout".utf8ByteSize)],
                 body := "Gateway Timeout".toUTF8 }
      IO.sleep 10
  return { status := 504, statusText := "Gateway Timeout",
           headers := #[("Content-Type", "text/plain"),
                        ("Content-Length", toString "Gateway Timeout".utf8ByteSize)],
           body := "Gateway Timeout".toUTF8 }

end LeanHTTP
