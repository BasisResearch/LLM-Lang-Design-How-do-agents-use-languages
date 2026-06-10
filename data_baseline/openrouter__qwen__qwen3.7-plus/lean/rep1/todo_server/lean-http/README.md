# lean-http

Pure Lean 4 HTTP/1.1 server library inspired by [go-chi/chi](https://github.com/go-chi/chi).

No C FFI. No external dependencies. Just Lean 4 standard library.

## Quick Start

```lean
import LeanHTTP
open LeanHTTP

def main : IO Unit := do
  let r ← Router.new
  r.use loggerMiddleware
  r.get "/hello" (fun _ => pure (HttpResponse.ok "Hello!"))
  r.get "/users/{id}" (fun req => do
    let id := (req.param "id").getD "?"
    pure (HttpResponse.json 200 s!"\{\"id\": \"{id}\"}"))
  r.listen 8080
```

## Features

### Router

Chi-style trie router with path parameters and wildcard catch-all.

```lean
let r ← Router.new

-- Static routes
r.get "/health" handler
r.post "/users" handler

-- Path parameters
r.get "/users/{id}" (fun req => do
  let id := (req.param "id").getD "?"
  pure (HttpResponse.ok id))

-- Wildcard catch-all
r.get "/static/*" (fun req => do
  let path := (req.param "*").getD ""
  pure (HttpResponse.ok s!"file: {path}"))

-- Route grouping
r.route "/api" fun api => do
  api.get "/users" listUsers
  api.post "/users" createUser
```

HEAD requests automatically fall back to GET handlers. Unmatched methods return 405 with an `Allow` header. Trailing slashes are normalized.

### Middleware

Middleware composes as `Handler → Handler`.

```lean
-- Built-in middleware
r.use loggerMiddleware                     -- request timing logs
r.use recovererMiddleware                  -- panic recovery → 500
r.use (corsMiddleware {})                  -- CORS with preflight
r.use requestIdMiddleware                  -- X-Request-Id header
r.use (timeoutMiddleware 30000)            -- 30s handler timeout → 504

-- Rate limiting (returns IO Middleware)
let rl ← rateLimitMiddleware { maxRequests := 100, windowMs := 60000 }
r.use rl
```

### Request Context

Pass data between middleware and handlers via request-scoped context.

```lean
let authMw : Middleware := fun next req => do
  match req.header "authorization" with
  | some token => next (req.withCtx "userId" token)
  | none => pure (HttpResponse.json 401 "{\"error\": \"unauthorized\"}")

-- In handler:
match req.ctx "userId" with
| some uid => pure (HttpResponse.ok uid)
| none => pure (HttpResponse.badRequest "no user")
```

### Request Helpers

```lean
req.param "id"              -- URL path parameter
req.paramNat "id"           -- URL path parameter as Nat
req.queryParam "page"       -- query string parameter
req.header "content-type"   -- case-insensitive header lookup
req.contentType             -- shorthand for Content-Type
req.userAgent               -- shorthand for User-Agent
req.cookie "session"        -- parse Cookie header
req.ctx "key"               -- middleware context value
```

### Response Builders

```lean
HttpResponse.ok "hello"                          -- 200 text/plain
HttpResponse.json 200 "{\"ok\":true}"            -- 200 application/json
HttpResponse.html 200 "<h1>Hello</h1>"           -- 200 text/html
HttpResponse.text 202 "accepted"                 -- 202 text/plain
HttpResponse.created "done"                      -- 201
HttpResponse.noContent                           -- 204
HttpResponse.badRequest "invalid"                -- 400
HttpResponse.notFound                            -- 404
HttpResponse.redirect "/new-url"                 -- 302
HttpResponse.movedPermanently "/new"             -- 301
HttpResponse.temporaryRedirect "/temp"           -- 307
HttpResponse.permanentRedirect "/perm"           -- 308
```

### Cookies

```lean
-- Read
let session := req.cookie "session_id"

-- Write
let resp := (HttpResponse.ok "logged in").setCookie "session_id" "abc123"
  { secure := true, httpOnly := true, sameSite := some "Strict", maxAge := some 3600 }
```

### Server Configuration

```lean
let server ← router.serve {
  port := 8080
  maxConnections := 1024       -- 503 on excess
  readTimeoutMs := 30000       -- 408 on slow clients
  keepAliveTimeoutMs := 5000   -- idle connection timeout
  maxHeaderSize := 8192        -- 8KB header limit
  maxBodySize := 1048576       -- 1MB body limit
}

-- Graceful shutdown
server.shutdown
```

For simple use: `router.listen 8080` blocks forever.

### Debugging

```lean
r.printRoutes
-- Output:
-- Registered routes:
--   GET /health
--   GET /users/{id}
--   POST /users
```

## Requirements

- Lean 4 v4.27.0 (`leanprover/lean4:v4.27.0`)

## Build

```sh
lake build           # library
lake build example   # example server
lake build tests     # test suite
.lake/build/bin/tests  # run tests
```

## Architecture

```
LeanHTTP/
├── Types.lean       -- HttpMethod, HttpRequest, HttpResponse, Handler, Middleware
├── Parser.lean      -- HTTP/1.1 parser (URL decode, path normalize, size limits)
├── Router.lean      -- Trie-based router (params, wildcards, route groups)
├── Middleware.lean   -- Logger, recoverer, CORS, requestId, rate limit, timeout
├── Context.lean     -- Request helper methods (param, header, cookie, context)
├── Response.lean    -- Response builders and serializer
├── Cookie.lean      -- Cookie parsing and Set-Cookie builder
└── Server.lean      -- TCP server (keep-alive, concurrent, graceful shutdown)
```

## License

MIT
