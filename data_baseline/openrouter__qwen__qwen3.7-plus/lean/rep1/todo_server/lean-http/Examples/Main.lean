import LeanHTTP

open LeanHTTP

-- Handlers

def healthCheck : Handler := fun _req =>
  pure (HttpResponse.ok "OK")

def listUsers : Handler := fun _req =>
  pure (HttpResponse.json 200 "{\"users\": []}")

def getUser : Handler := fun req => do
  match req.paramNat "id" with
  | some id => pure (HttpResponse.json 200 s!"\{\"id\": {id}}")
  | none => pure (HttpResponse.badRequest "invalid id")

def createUser : Handler := fun _req =>
  pure (HttpResponse.created "{\"id\": 1}")

def serveFile : Handler := fun req => do
  let path := (req.param "*").getD ""
  pure (HttpResponse.ok s!"serving: {path}")

def profile : Handler := fun req => do
  match req.ctx "userId" with
  | some uid => pure (HttpResponse.json 200 s!"\{\"userId\": \"{uid}\"}")
  | none => pure (HttpResponse.json 401 "{\"error\": \"unauthorized\"}")

def homepage : Handler := fun _req =>
  pure (HttpResponse.html 200 "<html><body><h1>lean-http</h1></body></html>")

-- Auth middleware example: sets userId in context
def authMiddleware : Middleware := fun next req => do
  match req.header "authorization" with
  | some token =>
    let reqWithCtx := req.withCtx "userId" token
    next reqWithCtx
  | none => next req

def main : IO Unit := do
  let r ← Router.new

  -- Global middleware stack
  r.use loggerMiddleware
  r.use recovererMiddleware
  r.use (corsMiddleware {})
  r.use requestIdMiddleware
  let rl ← rateLimitMiddleware { maxRequests := 1000, windowMs := 60000 }
  r.use rl
  r.use (timeoutMiddleware 30000)
  r.use authMiddleware

  -- Routes
  r.get "/" homepage
  r.get "/health" healthCheck
  r.get "/static/*" serveFile

  r.route "/api" fun api => do
    api.get "/users" listUsers
    api.get "/users/{id}" getUser
    api.post "/users" createUser
    api.get "/profile" profile

  -- Debug: print registered routes
  r.printRoutes

  -- Start server
  r.listen 8080
