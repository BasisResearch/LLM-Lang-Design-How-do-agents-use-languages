import LeanHTTP.Types
import LeanHTTP.Context
import LeanHTTP.Response
import LeanHTTP.Middleware
import Std.Data.HashMap

namespace LeanHTTP

/-- Node data in the routing trie. Uses Nat indices instead of IO.Ref to avoid
    nested inductive type issues. Nodes are stored in a flat array (node pool). -/
structure NodeData where
  handlers : Array (String × Handler)
  children : Array (String × Nat)       -- (segment, nodeIndex)
  paramChild : Option (String × Nat)    -- (paramName, nodeIndex)
  catchAll : Option (String × Array (String × Handler))  -- (paramName, [(method, handler)])

instance : Inhabited NodeData where
  default := { handlers := #[], children := #[], paramChild := none, catchAll := none }

def NodeData.empty : NodeData := default

/-- Chi-style HTTP router with trie-based routing and middleware support -/
structure Router where
  nodes : IO.Ref (Array NodeData)   -- node pool; index 0 is root
  middlewares : IO.Ref (Array Middleware)
  pathPrefix : String

namespace Router

def new : IO Router := do
  let nodes ← IO.mkRef #[NodeData.empty]  -- root at index 0
  let mws ← IO.mkRef #[]
  return { nodes := nodes, middlewares := mws, pathPrefix := "" }

def use (router : Router) (mw : Middleware) : IO Unit :=
  router.middlewares.modify (·.push mw)

/-- Split path into segments: "/users/{id}/posts" → ["users", "{id}", "posts"] -/
private def splitPath (path : String) : List String :=
  (path.splitOn "/").filter (· != "")

/-- Check if a segment is a param pattern like "{id}", return param name -/
private def extractParam (segment : String) : Option String :=
  if segment.startsWith "{" && segment.endsWith "}" then
    let chars := segment.toList
    some (String.ofList (chars.drop 1 |>.dropLast))
  else
    none

/-- Allocate a new empty node, return its index -/
private def allocNode (router : Router) : IO Nat := do
  let ns ← router.nodes.get
  let idx := ns.size
  router.nodes.set (ns.push NodeData.empty)
  return idx

/-- Get node data by index -/
private def getNode (router : Router) (idx : Nat) : IO NodeData := do
  let ns ← router.nodes.get
  return ns[idx]!

/-- Set node data by index -/
private def setNode (router : Router) (idx : Nat) (node : NodeData) : IO Unit :=
  router.nodes.modify (·.set! idx node)

/-- Find child index for a given segment -/
private def findChildIdx (node : NodeData) (segment : String) : Option Nat :=
  match node.children.find? (fun (s, _) => s == segment) with
  | some (_, idx) => some idx
  | none => none

/-- Find handler for a given method -/
private def findHandler (node : NodeData) (method : String) : Option Handler :=
  match node.handlers.find? (fun (m, _) => m == method) with
  | some (_, h) => some h
  | none => none

/-- Collect all registered methods at a node -/
private def collectMethods (node : NodeData) : Array String :=
  node.handlers.map (fun (m, _) => m)

/-- Insert a route into the trie -/
private partial def insertRoute (router : Router) (nodeIdx : Nat) (segments : List String)
    (method : String) (handler : Handler) : IO Unit := do
  match segments with
  | [] =>
    let node ← getNode router nodeIdx
    let handlers := match node.handlers.findIdx? (fun (m, _) => m == method) with
      | some i => node.handlers.set! i (method, handler)
      | none => node.handlers.push (method, handler)
    setNode router nodeIdx { node with handlers := handlers }
  | seg :: rest =>
    if seg == "*" then
      let node ← getNode router nodeIdx
      let catchAllData := match node.catchAll with
      | some (name, handlers) =>
        let h := match handlers.findIdx? (fun (m, _) => m == method) with
          | some i => handlers.set! i (method, handler)
          | none => handlers.push (method, handler)
        (name, h)
      | none => ("*", #[(method, handler)])
      setNode router nodeIdx { node with catchAll := some catchAllData }
    else
      match extractParam seg with
      | some paramName =>
        let node ← getNode router nodeIdx
        match node.paramChild with
        | some (_, childIdx) =>
          insertRoute router childIdx rest method handler
        | none =>
          let childIdx ← allocNode router
          let node ← getNode router nodeIdx  -- re-read after alloc
          setNode router nodeIdx { node with paramChild := some (paramName, childIdx) }
          insertRoute router childIdx rest method handler
      | none =>
        let node ← getNode router nodeIdx
        match findChildIdx node seg with
        | some childIdx =>
          insertRoute router childIdx rest method handler
        | none =>
          let childIdx ← allocNode router
          let node ← getNode router nodeIdx  -- re-read after alloc
          setNode router nodeIdx { node with children := node.children.push (seg, childIdx) }
          insertRoute router childIdx rest method handler

/-- Add a route with method and pattern -/
def addRoute (router : Router) (method : HttpMethod) (pattern : String)
    (handler : Handler) : IO Unit := do
  let fullPattern := router.pathPrefix ++ pattern
  let segments := splitPath fullPattern
  insertRoute router 0 segments (toString method) handler

def get (router : Router) (pattern : String) (handler : Handler) : IO Unit :=
  router.addRoute .GET pattern handler

def post (router : Router) (pattern : String) (handler : Handler) : IO Unit :=
  router.addRoute .POST pattern handler

def put (router : Router) (pattern : String) (handler : Handler) : IO Unit :=
  router.addRoute .PUT pattern handler

def delete (router : Router) (pattern : String) (handler : Handler) : IO Unit :=
  router.addRoute .DELETE pattern handler

/-- Route grouping: mount routes under a prefix -/
def route (router : Router) (rPrefix : String) (fn : Router → IO Unit) : IO Unit := do
  let subRouter : Router := { router with pathPrefix := router.pathPrefix ++ rPrefix }
  fn subRouter

/-- Lookup a route in the trie, collecting param values -/
private partial def lookupRoute (router : Router) (nodeIdx : Nat) (segments : List String)
    (method : String) (params : Array (String × String))
    : IO (Option (Handler × Array (String × String))) := do
  match segments with
  | [] =>
    let node ← getNode router nodeIdx
    match findHandler node method with
    | some handler => return some (handler, params)
    | none =>
      -- HEAD falls back to GET
      if method == "HEAD" then
        match findHandler node "GET" with
        | some handler => return some (handler, params)
        | none => return none
      else return none
  | seg :: rest =>
    let node ← getNode router nodeIdx
    -- Try static match first
    match findChildIdx node seg with
    | some childIdx =>
      let result ← lookupRoute router childIdx rest method params
      match result with
      | some r => return some r
      | none =>
        -- Fall through to param match
        match node.paramChild with
        | some (paramName, childIdx) =>
          let result2 ← lookupRoute router childIdx rest method (params.push (paramName, seg))
          match result2 with
          | some r => return some r
          | none =>
            -- Fall through to catchAll
            match node.catchAll with
            | some (paramName, handlers) =>
              let wildcardValue := "/" ++ "/".intercalate (seg :: rest)
              match handlers.find? (fun (m, _) => m == method) with
              | some (_, handler) =>
                return some (handler, params.push (paramName, wildcardValue))
              | none =>
                if method == "HEAD" then
                  match handlers.find? (fun (m, _) => m == "GET") with
                  | some (_, handler) =>
                    return some (handler, params.push (paramName, wildcardValue))
                  | none => return none
                else return none
            | none => return none
        | none =>
          -- Try catchAll
          match node.catchAll with
          | some (paramName, handlers) =>
            let wildcardValue := "/" ++ "/".intercalate (seg :: rest)
            match handlers.find? (fun (m, _) => m == method) with
            | some (_, handler) =>
              return some (handler, params.push (paramName, wildcardValue))
            | none =>
              if method == "HEAD" then
                match handlers.find? (fun (m, _) => m == "GET") with
                | some (_, handler) =>
                  return some (handler, params.push (paramName, wildcardValue))
                | none => return none
              else return none
          | none => return none
    | none =>
      -- Try param match
      match node.paramChild with
      | some (paramName, childIdx) =>
        let result ← lookupRoute router childIdx rest method (params.push (paramName, seg))
        match result with
        | some r => return some r
        | none =>
          -- Fall through to catchAll
          match node.catchAll with
          | some (paramName, handlers) =>
            let wildcardValue := "/" ++ "/".intercalate (seg :: rest)
            match handlers.find? (fun (m, _) => m == method) with
            | some (_, handler) =>
              return some (handler, params.push (paramName, wildcardValue))
            | none =>
              if method == "HEAD" then
                match handlers.find? (fun (m, _) => m == "GET") with
                | some (_, handler) =>
                  return some (handler, params.push (paramName, wildcardValue))
                | none => return none
              else return none
          | none => return none
      | none =>
        -- Try catchAll
        match node.catchAll with
        | some (paramName, handlers) =>
          let wildcardValue := "/" ++ "/".intercalate (seg :: rest)
          match handlers.find? (fun (m, _) => m == method) with
          | some (_, handler) =>
            return some (handler, params.push (paramName, wildcardValue))
          | none =>
            if method == "HEAD" then
              match handlers.find? (fun (m, _) => m == "GET") with
              | some (_, handler) =>
                return some (handler, params.push (paramName, wildcardValue))
              | none => return none
            else return none
        | none => return none

/-- Lookup a path in the trie regardless of method, to find if the path exists -/
private partial def lookupPath (router : Router) (nodeIdx : Nat) (segments : List String)
    (params : Array (String × String))
    : IO (Option (NodeData × Array (String × String))) := do
  match segments with
  | [] =>
    let node ← getNode router nodeIdx
    return some (node, params)
  | seg :: rest =>
    let node ← getNode router nodeIdx
    -- Try static match first
    match findChildIdx node seg with
    | some childIdx =>
      let result ← lookupPath router childIdx rest params
      match result with
      | some r => return some r
      | none =>
        match node.paramChild with
        | some (paramName, childIdx) =>
          lookupPath router childIdx rest (params.push (paramName, seg))
        | none =>
          -- Check catchAll
          match node.catchAll with
          | some _ => return some (node, params)
          | none => return none
    | none =>
      match node.paramChild with
      | some (paramName, childIdx) =>
        let result ← lookupPath router childIdx rest (params.push (paramName, seg))
        match result with
        | some r => return some r
        | none =>
          match node.catchAll with
          | some _ => return some (node, params)
          | none => return none
      | none =>
        match node.catchAll with
        | some _ => return some (node, params)
        | none => return none

/-- Convert params array to HashMap -/
private def paramsToHashMap (params : Array (String × String)) : Std.HashMap String String :=
  params.foldl (fun (acc : Std.HashMap String String) (k, v) => acc.insert k v) {}

/-- Dispatch a request through middleware chain and router -/
def dispatch (router : Router) (req : HttpRequest) : IO HttpResponse := do
  -- Normalize trailing slash (except for root "/")
  let normalizedPath := if req.path != "/" && req.path.endsWith "/" then
    String.ofList (req.path.toList.dropLast)
  else req.path
  let segments := splitPath normalizedPath
  let method := toString req.method
  match ← lookupRoute router 0 segments method #[] with
  | some (handler, params) =>
    let reqWithParams : HttpRequest := { req with params := paramsToHashMap params }
    let mws ← router.middlewares.get
    let wrappedHandler := mws.foldr (fun mw h => mw h) handler
    wrappedHandler reqWithParams
  | none =>
    -- Check if path exists with different method -> 405
    match ← lookupPath router 0 segments #[] with
    | some (node, _) =>
      let methods := collectMethods node
      if methods.isEmpty then return HttpResponse.notFound
      -- Add HEAD if GET is registered
      let methods := if methods.any (· == "GET") && !methods.any (· == "HEAD")
        then methods.push "HEAD" else methods
      return HttpResponse.methodNotAllowedWith methods
    | none => return HttpResponse.notFound

/-- Route info for debugging -/
structure RouteInfo where
  method : String
  pattern : String
  deriving Repr

/-- Walk the trie recursively, collecting method+pattern pairs -/
private partial def walkNode (router : Router) (nodeIdx : Nat) (currentPath : String)
    (result : IO.Ref (Array RouteInfo)) : IO Unit := do
  let node ← getNode router nodeIdx
  -- Collect handlers at this node
  for (method, _) in node.handlers do
    let pattern := if currentPath.isEmpty then "/" else currentPath
    result.modify (·.push { method, pattern })
  -- Collect catchAll handlers
  match node.catchAll with
  | some (_, handlers) =>
    for (method, _) in handlers do
      result.modify (·.push { method, pattern := currentPath ++ "/*" })
  | none => pure ()
  -- Recurse into static children
  for (segment, childIdx) in node.children do
    walkNode router childIdx (currentPath ++ "/" ++ segment) result
  -- Recurse into param child
  match node.paramChild with
  | some (paramName, childIdx) =>
    walkNode router childIdx (currentPath ++ "/{" ++ paramName ++ "}") result
  | none => pure ()

/-- Collect all registered routes (for debugging) -/
def routes (router : Router) : IO (Array RouteInfo) := do
  let result ← IO.mkRef (#[] : Array RouteInfo)
  walkNode router 0 "" result
  result.get

/-- Print all routes (for debugging) -/
def printRoutes (router : Router) : IO Unit := do
  let rs ← router.routes
  IO.println "Registered routes:"
  for r in rs do
    IO.println s!"  {r.method} {r.pattern}"

end Router
end LeanHTTP
