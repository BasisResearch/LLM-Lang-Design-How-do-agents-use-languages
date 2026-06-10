import LeanHTTP

open LeanHTTP

/-- Simple test assertion -/
def assert (name : String) (condition : Bool) : IO Unit := do
  if condition then
    IO.println s!"  ✓ {name}"
  else
    throw (IO.userError s!"  ✗ FAILED: {name}")

/-- Check if a string contains a substring -/
def String.contains' (s sub : String) : Bool :=
  (s.splitOn sub).length > 1

/-- Build a raw HTTP request ByteArray from string -/
def mkRawRequest (s : String) : ByteArray := s.toUTF8

-- ============================================================
-- Parser Tests
-- ============================================================

def testParserSimpleGet : IO Unit := do
  IO.println "Parser: simple GET"
  let raw := mkRawRequest "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n"
  match parseRequest raw with
  | some req =>
    assert "method is GET" (req.method == .GET)
    assert "path is /hello" (req.path == "/hello")
    assert "has Host header" (req.headers.any (fun (k, _) => k == "Host"))
  | none => throw (IO.userError "  ✗ FAILED: parseRequest returned none")

def testParserPostWithBody : IO Unit := do
  IO.println "Parser: POST with body"
  let body := "{\"name\":\"test\"}"
  let raw := mkRawRequest s!"POST /users HTTP/1.1\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
  match parseRequest raw with
  | some req =>
    assert "method is POST" (req.method == .POST)
    assert "path is /users" (req.path == "/users")
    assert "body matches" (String.fromUTF8! req.body == body)
  | none => throw (IO.userError "  ✗ FAILED: parseRequest returned none")

def testParserQueryParams : IO Unit := do
  IO.println "Parser: query parameters"
  let raw := mkRawRequest "GET /search?q=lean&page=1 HTTP/1.1\r\n\r\n"
  match parseRequest raw with
  | some req =>
    assert "path is /search" (req.path == "/search")
    assert "query q=lean" (req.queryParam "q" == some "lean")
    assert "query page=1" (req.queryParam "page" == some "1")
  | none => throw (IO.userError "  ✗ FAILED: parseRequest returned none")

def testParserMultipleHeaders : IO Unit := do
  IO.println "Parser: multiple headers"
  let raw := mkRawRequest "GET / HTTP/1.1\r\nHost: localhost\r\nAccept: text/html\r\nUser-Agent: test\r\n\r\n"
  match parseRequest raw with
  | some req =>
    assert "has 3 headers" (req.headers.size == 3)
  | none => throw (IO.userError "  ✗ FAILED: parseRequest returned none")

def testParserMalformed : IO Unit := do
  IO.println "Parser: malformed request"
  let raw := mkRawRequest "INVALID REQUEST\r\n\r\n"
  match parseRequest raw with
  | some _ => throw (IO.userError "  ✗ FAILED: should have returned none for malformed request")
  | none => assert "returns none for malformed" true

-- URL Decoding tests
def testUrlDecoding : IO Unit := do
  IO.println "Parser: URL decoding"
  let raw := mkRawRequest "GET /hello%20world HTTP/1.1\r\n\r\n"
  match parseRequest raw with
  | some req =>
    assert "path decoded" (req.path == "/hello world")
  | none => throw (IO.userError "  ✗ FAILED: parseRequest returned none")

def testUrlDecodingQuery : IO Unit := do
  IO.println "Parser: URL decoding in query"
  let raw := mkRawRequest "GET /search?q=hello+world&tag=%23lean HTTP/1.1\r\n\r\n"
  match parseRequest raw with
  | some req =>
    assert "query + decoded" (req.queryParam "q" == some "hello world")
    assert "query % decoded" (req.queryParam "tag" == some "#lean")
  | none => throw (IO.userError "  ✗ FAILED: parseRequest returned none")

-- Path normalization tests
def testPathNormalization : IO Unit := do
  IO.println "Parser: path normalization"
  let raw1 := mkRawRequest "GET /a//b HTTP/1.1\r\n\r\n"
  let raw2 := mkRawRequest "GET /a/./b HTTP/1.1\r\n\r\n"
  let raw3 := mkRawRequest "GET /a/b/../c HTTP/1.1\r\n\r\n"
  match parseRequest raw1, parseRequest raw2, parseRequest raw3 with
  | some r1, some r2, some r3 =>
    assert "// collapsed" (r1.path == "/a/b")
    assert "/. resolved" (r2.path == "/a/b")
    assert "/.. resolved" (r3.path == "/a/c")
  | _, _, _ => throw (IO.userError "  ✗ FAILED: parseRequest returned none")

def testPathTraversalBlocked : IO Unit := do
  IO.println "Parser: path traversal blocked"
  let raw := mkRawRequest "GET /../../etc/passwd HTTP/1.1\r\n\r\n"
  match parseRequest raw with
  | some _ => throw (IO.userError "  ✗ FAILED: should reject path traversal")
  | none => assert "traversal blocked" true

-- Size limit tests
def testHeaderSizeLimit : IO Unit := do
  IO.println "Parser: header size limit"
  -- Create a request with huge headers (> 8KB)
  let bigHeader := String.ofList (List.replicate 9000 'X')
  let raw := mkRawRequest s!"GET / HTTP/1.1\r\nX-Big: {bigHeader}\r\n\r\n"
  let config : LeanHTTP.ParseConfig := { maxHeaderSize := 8192, maxBodySize := 1048576 }
  match parseRequest raw config with
  | some _ => throw (IO.userError "  ✗ FAILED: should reject oversized headers")
  | none => assert "oversized header rejected" true

def testBodySizeLimit : IO Unit := do
  IO.println "Parser: body size limit"
  let raw := mkRawRequest "POST / HTTP/1.1\r\nContent-Length: 2000000\r\n\r\nbody"
  let config : LeanHTTP.ParseConfig := { maxHeaderSize := 8192, maxBodySize := 1048576 }
  match parseRequest raw config with
  | some _ => throw (IO.userError "  ✗ FAILED: should reject oversized body")
  | none => assert "oversized body rejected" true

-- ============================================================
-- Router Tests
-- ============================================================

def mkRequest (method : HttpMethod) (path : String) : HttpRequest :=
  { method := method, path := path, headers := #[], body := ByteArray.empty,
    params := {}, query := {}, context := {} }

def testRouterStaticRoute : IO Unit := do
  IO.println "Router: static route matching"
  let r ← Router.new
  r.get "/hello" (fun _ => pure (HttpResponse.ok "hello"))
  let resp ← r.dispatch (mkRequest .GET "/hello")
  assert "status 200" (resp.status == 200)
  assert "body is hello" (String.fromUTF8! resp.body == "hello")

def testRouterParamRoute : IO Unit := do
  IO.println "Router: param route matching"
  let r ← Router.new
  r.get "/users/{id}" (fun req => do
    match req.param "id" with
    | some id => pure (HttpResponse.ok s!"user:{id}")
    | none => pure (HttpResponse.badRequest "no id"))
  let resp ← r.dispatch (mkRequest .GET "/users/42")
  assert "status 200" (resp.status == 200)
  assert "body has param" (String.fromUTF8! resp.body == "user:42")

def testRouterMultipleParams : IO Unit := do
  IO.println "Router: multiple params"
  let r ← Router.new
  r.get "/users/{userId}/posts/{postId}" (fun req => do
    let uid := (req.param "userId").getD "?"
    let pid := (req.param "postId").getD "?"
    pure (HttpResponse.ok s!"{uid}:{pid}"))
  let resp ← r.dispatch (mkRequest .GET "/users/5/posts/10")
  assert "status 200" (resp.status == 200)
  assert "both params extracted" (String.fromUTF8! resp.body == "5:10")

def testRouter404 : IO Unit := do
  IO.println "Router: 404 for unmatched"
  let r ← Router.new
  r.get "/exists" (fun _ => pure (HttpResponse.ok "yes"))
  let resp ← r.dispatch (mkRequest .GET "/nope")
  assert "status 404" (resp.status == 404)

def testRouterMethodSpecific : IO Unit := do
  IO.println "Router: method-specific routing"
  let r ← Router.new
  r.get "/resource" (fun _ => pure (HttpResponse.ok "get"))
  r.post "/resource" (fun _ => pure (HttpResponse.ok "post"))
  let getResp ← r.dispatch (mkRequest .GET "/resource")
  let postResp ← r.dispatch (mkRequest .POST "/resource")
  let delResp ← r.dispatch (mkRequest .DELETE "/resource")
  assert "GET returns get" (String.fromUTF8! getResp.body == "get")
  assert "POST returns post" (String.fromUTF8! postResp.body == "post")
  assert "DELETE returns 405" (delResp.status == 405)

def testRouterRouteGroup : IO Unit := do
  IO.println "Router: route grouping"
  let r ← Router.new
  r.route "/api" fun api => do
    api.get "/users" (fun _ => pure (HttpResponse.ok "users"))
    api.get "/posts" (fun _ => pure (HttpResponse.ok "posts"))
  let resp1 ← r.dispatch (mkRequest .GET "/api/users")
  let resp2 ← r.dispatch (mkRequest .GET "/api/posts")
  let resp3 ← r.dispatch (mkRequest .GET "/users")
  assert "/api/users works" (String.fromUTF8! resp1.body == "users")
  assert "/api/posts works" (String.fromUTF8! resp2.body == "posts")
  assert "/users without prefix is 404" (resp3.status == 404)

-- ============================================================
-- Response Tests
-- ============================================================

def testResponseSerialization : IO Unit := do
  IO.println "Response: serialization"
  let resp := HttpResponse.ok "hello"
  let bytes := resp.toByteArray
  let str := String.fromUTF8! bytes
  assert "starts with HTTP/1.1" (str.startsWith "HTTP/1.1 200 OK")
  assert "contains Content-Type" (str.contains' "Content-Type: text/plain")
  assert "no Connection: close by default" (!str.contains' "Connection: close")
  assert "body at end" (str.endsWith "hello")

def testResponseJson : IO Unit := do
  IO.println "Response: JSON helper"
  let resp := HttpResponse.json 201 "{\"ok\":true}"
  assert "status 201" (resp.status == 201)
  let bytes := resp.toByteArray
  let str := String.fromUTF8! bytes
  assert "content-type json" (str.contains' "Content-Type: application/json")

-- ============================================================
-- Middleware Tests
-- ============================================================

def testMiddlewareChain : IO Unit := do
  IO.println "Middleware: chain application"
  let r ← Router.new
  let testMw : Middleware := fun next req => do
    let resp ← next req
    let newBody := "MW:" ++ (String.fromUTF8! resp.body)
    pure { resp with body := newBody.toUTF8 }
  r.use testMw
  r.get "/test" (fun _ => pure (HttpResponse.ok "inner"))
  let resp ← r.dispatch (mkRequest .GET "/test")
  assert "middleware wraps response" (String.fromUTF8! resp.body == "MW:inner")

-- ============================================================
-- Content-Length Validation Tests
-- ============================================================

def testContentLengthValidation : IO Unit := do
  IO.println "Parser: Content-Length validation"
  -- Multiple Content-Length headers
  let raw1 := mkRawRequest "GET / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 10\r\n\r\nhello"
  assert "multiple CL rejected" (parseRequest raw1).isNone
  -- Non-numeric Content-Length
  let raw2 := mkRawRequest "POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n"
  assert "non-numeric CL rejected" (parseRequest raw2).isNone

def testResponseNoConnectionClose : IO Unit := do
  IO.println "Response: no default Connection: close"
  let resp := HttpResponse.ok "hello"
  let str := String.fromUTF8! resp.toByteArray
  assert "no Connection: close by default" (!str.contains' "Connection: close")

-- ============================================================
-- HEAD / 405 / Wildcard / Trailing Slash Tests
-- ============================================================

def testHeadMethod : IO Unit := do
  IO.println "Router: HEAD method"
  let r ← Router.new
  r.get "/hello" (fun _ => pure (HttpResponse.ok "hello"))
  let resp ← r.dispatch (mkRequest .HEAD "/hello")
  assert "HEAD gets 200" (resp.status == 200)

def testMethodNotAllowed : IO Unit := do
  IO.println "Router: 405 Method Not Allowed"
  let r ← Router.new
  r.get "/resource" (fun _ => pure (HttpResponse.ok "ok"))
  r.post "/resource" (fun _ => pure (HttpResponse.ok "ok"))
  let resp ← r.dispatch (mkRequest .DELETE "/resource")
  assert "status 405" (resp.status == 405)
  assert "has Allow header" (resp.headers.any (fun (k, _) => k == "Allow"))

def testWildcardRoute : IO Unit := do
  IO.println "Router: wildcard route"
  let r ← Router.new
  r.get "/static/*" (fun req => do
    let path := (req.param "*").getD ""
    pure (HttpResponse.ok s!"file:{path}"))
  let resp ← r.dispatch (mkRequest .GET "/static/css/style.css")
  assert "status 200" (resp.status == 200)
  assert "wildcard captured" (String.fromUTF8! resp.body == "file:/css/style.css")

def testTrailingSlash : IO Unit := do
  IO.println "Router: trailing slash"
  let r ← Router.new
  r.get "/users" (fun _ => pure (HttpResponse.ok "users"))
  let resp ← r.dispatch (mkRequest .GET "/users/")
  assert "trailing slash matches" (resp.status == 200)

-- ============================================================
-- CORS Middleware Tests
-- ============================================================

def mkRequestWithHeaders (method : HttpMethod) (path : String) (headers : Array (String × String)) : HttpRequest :=
  { method := method, path := path, headers := headers, body := ByteArray.empty,
    params := {}, query := {}, context := {} }

def testCorsMiddleware : IO Unit := do
  IO.println "CORS: headers added to response"
  let handler : Handler := fun _ => pure (HttpResponse.ok "hello")
  let mw := corsMiddleware {}
  let wrappedHandler := mw handler
  let req := mkRequestWithHeaders .GET "/test" #[("Origin", "http://example.com")]
  let resp ← wrappedHandler req
  assert "status 200" (resp.status == 200)
  assert "has Allow-Origin" (resp.headers.any (fun (k, _) => k == "Access-Control-Allow-Origin"))
  let originVal := (resp.headers.find? (fun (k, _) => k == "Access-Control-Allow-Origin")).map (·.2)
  assert "Allow-Origin is *" (originVal == some "*")

def testCorsPreflight : IO Unit := do
  IO.println "CORS: preflight returns 204 with headers"
  let handler : Handler := fun _ => pure (HttpResponse.ok "should not reach")
  let mw := corsMiddleware {}
  let wrappedHandler := mw handler
  let req := mkRequestWithHeaders .OPTIONS "/test" #[("Origin", "http://example.com")]
  let resp ← wrappedHandler req
  assert "status 204" (resp.status == 204)
  assert "has Allow-Origin" (resp.headers.any (fun (k, _) => k == "Access-Control-Allow-Origin"))
  assert "has Allow-Methods" (resp.headers.any (fun (k, _) => k == "Access-Control-Allow-Methods"))
  assert "has Allow-Headers" (resp.headers.any (fun (k, _) => k == "Access-Control-Allow-Headers"))
  assert "has Max-Age" (resp.headers.any (fun (k, _) => k == "Access-Control-Max-Age"))
  assert "body is empty" (resp.body.size == 0)

def testRequestIdMiddleware : IO Unit := do
  IO.println "RequestID: X-Request-Id added to response"
  let handler : Handler := fun _ => pure (HttpResponse.ok "hello")
  let mw := requestIdMiddleware
  let wrappedHandler := mw handler
  -- Without existing request ID
  let req1 := mkRequest .GET "/test"
  let resp1 ← wrappedHandler req1
  assert "has X-Request-Id" (resp1.headers.any (fun (k, _) => k == "X-Request-Id"))
  let rid1 := (resp1.headers.find? (fun (k, _) => k == "X-Request-Id")).map (·.2)
  assert "generated id has req- prefix" (match rid1 with | some v => v.startsWith "req-" | none => false)
  -- With existing request ID
  let req2 := mkRequestWithHeaders .GET "/test" #[("X-Request-Id", "my-custom-id")]
  let resp2 ← wrappedHandler req2
  let rid2 := (resp2.headers.find? (fun (k, _) => k == "X-Request-Id")).map (·.2)
  assert "preserves existing id" (rid2 == some "my-custom-id")

-- ============================================================
-- Redirect Helper Tests
-- ============================================================

def testRedirectHelpers : IO Unit := do
  IO.println "Response: redirect helpers"
  let r302 := HttpResponse.redirect "https://example.com"
  assert "default redirect is 302" (r302.status == 302)
  assert "redirect has Location" (r302.headers.any (fun (k, v) => k == "Location" && v == "https://example.com"))
  let r301 := HttpResponse.movedPermanently "https://example.com/new"
  assert "movedPermanently is 301" (r301.status == 301)
  assert "301 has Location" (r301.headers.any (fun (k, v) => k == "Location" && v == "https://example.com/new"))
  let r307 := HttpResponse.temporaryRedirect "/tmp"
  assert "temporaryRedirect is 307" (r307.status == 307)
  let r308 := HttpResponse.permanentRedirect "/final"
  assert "permanentRedirect is 308" (r308.status == 308)

-- ============================================================
-- Cookie Tests
-- ============================================================

def testCookieRead : IO Unit := do
  IO.println "Cookie: read from request"
  let req : HttpRequest := { mkRequest .GET "/test" with headers := #[("Cookie", "foo=bar; baz=qux")] }
  assert "cookie foo=bar" (req.cookie "foo" == some "bar")
  assert "cookie baz=qux" (req.cookie "baz" == some "qux")
  assert "cookie missing" (req.cookie "missing" == none)

def testCookieWrite : IO Unit := do
  IO.println "Cookie: write to response"
  let resp := HttpResponse.ok "hello"
  let resp2 := resp.setCookie "session" "abc123" { httpOnly := true, secure := true }
  assert "has Set-Cookie header" (resp2.headers.any (fun (k, _) => k == "Set-Cookie"))
  let setCookieVal := resp2.headers.find? (fun (k, _) => k == "Set-Cookie")
  match setCookieVal with
  | some (_, v) =>
    assert "cookie name=value" (v.contains' "session=abc123")
    assert "cookie HttpOnly" (v.contains' "HttpOnly")
    assert "cookie Secure" (v.contains' "Secure")
    assert "cookie Path" (v.contains' "Path=/")
  | none => throw (IO.userError "  ✗ FAILED: Set-Cookie header not found")

-- ============================================================
-- Header Access Tests
-- ============================================================

def testHeaderAccess : IO Unit := do
  IO.println "Request: header access helpers"
  let req : HttpRequest := { mkRequest .GET "/test" with headers := #[("Content-Type", "application/json"), ("User-Agent", "TestBot/1.0"), ("X-Custom", "value")] }
  assert "header case-insensitive" (req.header "content-type" == some "application/json")
  assert "header exact case" (req.header "Content-Type" == some "application/json")
  assert "header upper case" (req.header "CONTENT-TYPE" == some "application/json")
  assert "contentType helper" (req.contentType == some "application/json")
  assert "userAgent helper" (req.userAgent == some "TestBot/1.0")
  assert "missing header" (req.header "X-Missing" == none)

-- ============================================================
-- HTML/Text Response Tests
-- ============================================================

def testHtmlResponse : IO Unit := do
  IO.println "Response: HTML helper"
  let resp := HttpResponse.html 200 "<h1>Hello</h1>"
  assert "status 200" (resp.status == 200)
  let str := String.fromUTF8! resp.toByteArray
  assert "content-type html" (str.contains' "Content-Type: text/html; charset=utf-8")
  assert "body present" (str.contains' "<h1>Hello</h1>")

def testTextResponse : IO Unit := do
  IO.println "Response: text helper"
  let resp := HttpResponse.text 202 "Accepted"
  assert "status 202" (resp.status == 202)
  let str := String.fromUTF8! resp.toByteArray
  assert "content-type text" (str.contains' "Content-Type: text/plain")
  assert "body present" (str.contains' "Accepted")

-- ============================================================
-- Rate Limiting Middleware Tests
-- ============================================================

def testRateLimitMiddleware : IO Unit := do
  IO.println "Middleware: rate limiting"
  let r ← Router.new
  let rl ← rateLimitMiddleware { maxRequests := 3, windowMs := 60000 }
  r.use rl
  r.get "/test" (fun _ => pure (HttpResponse.ok "ok"))
  let req := mkRequest .GET "/test"
  let resp1 ← r.dispatch req
  let resp2 ← r.dispatch req
  let resp3 ← r.dispatch req
  let resp4 ← r.dispatch req
  assert "first 3 requests succeed" (resp1.status == 200 && resp2.status == 200 && resp3.status == 200)
  assert "4th request rate limited" (resp4.status == 429)
  assert "has Retry-After" (resp4.headers.any (fun (k, _) => k == "Retry-After"))

-- ============================================================
-- Middleware Context Tests
-- ============================================================

def testMiddlewareContext : IO Unit := do
  IO.println "Middleware: context passing"
  let r ← Router.new
  -- Middleware that sets context
  let authMw : Middleware := fun next req => do
    let reqWithCtx := req.withCtx "userId" "42"
    next reqWithCtx
  r.use authMw
  r.get "/profile" (fun req => do
    match req.ctx "userId" with
    | some uid => pure (HttpResponse.ok s!"user:{uid}")
    | none => pure (HttpResponse.badRequest "no user"))
  let resp ← r.dispatch (mkRequest .GET "/profile")
  assert "status 200" (resp.status == 200)
  assert "context passed" (String.fromUTF8! resp.body == "user:42")

-- ============================================================
-- Route Dump Tests
-- ============================================================

def testRouteDump : IO Unit := do
  IO.println "Router: route list dump"
  let r ← Router.new
  r.get "/health" (fun _ => pure (HttpResponse.ok "ok"))
  r.get "/users/{id}" (fun _ => pure (HttpResponse.ok "ok"))
  r.post "/users" (fun _ => pure (HttpResponse.ok "ok"))
  let routes ← r.routes
  assert "has 3 routes" (routes.size == 3)
  assert "has GET /health" (routes.any (fun ri => ri.method == "GET" && ri.pattern == "/health"))
  assert "has GET /users/{id}" (routes.any (fun ri => ri.method == "GET" && ri.pattern == "/users/{id}"))
  assert "has POST /users" (routes.any (fun ri => ri.method == "POST" && ri.pattern == "/users"))

-- ============================================================
-- Timeout Middleware Tests
-- ============================================================

def testTimeoutMiddleware : IO Unit := do
  IO.println "Middleware: timeout"
  let r ← Router.new
  r.use (timeoutMiddleware 100)
  r.get "/fast" (fun _ => pure (HttpResponse.ok "fast"))
  r.get "/slow" (fun _ => do IO.sleep 500; pure (HttpResponse.ok "slow"))
  let fastResp ← r.dispatch (mkRequest .GET "/fast")
  assert "fast request succeeds" (fastResp.status == 200)
  let slowResp ← r.dispatch (mkRequest .GET "/slow")
  assert "slow request times out" (slowResp.status == 504)

-- ============================================================
-- Main
-- ============================================================

def main : IO UInt32 := do
  let mut failures : Nat := 0
  let tests : Array (IO Unit) := #[
    testParserSimpleGet,
    testParserPostWithBody,
    testParserQueryParams,
    testParserMultipleHeaders,
    testParserMalformed,
    testUrlDecoding,
    testUrlDecodingQuery,
    testPathNormalization,
    testPathTraversalBlocked,
    testHeaderSizeLimit,
    testBodySizeLimit,
    testRouterStaticRoute,
    testRouterParamRoute,
    testRouterMultipleParams,
    testRouter404,
    testRouterMethodSpecific,
    testRouterRouteGroup,
    testResponseSerialization,
    testResponseJson,
    testMiddlewareChain,
    testContentLengthValidation,
    testResponseNoConnectionClose,
    testHeadMethod,
    testMethodNotAllowed,
    testWildcardRoute,
    testTrailingSlash,
    testCorsMiddleware,
    testCorsPreflight,
    testRequestIdMiddleware,
    testRedirectHelpers,
    testCookieRead,
    testCookieWrite,
    testHeaderAccess,
    testHtmlResponse,
    testTextResponse,
    testRateLimitMiddleware,
    testTimeoutMiddleware,
    testMiddlewareContext,
    testRouteDump
  ]
  for test in tests do
    try
      test
    catch e =>
      IO.eprintln (toString e)
      failures := failures + 1
  IO.println ""
  if failures > 0 then
    IO.eprintln s!"{failures} test(s) failed"
    return 1
  else
    IO.println "All tests passed!"
    return 0
