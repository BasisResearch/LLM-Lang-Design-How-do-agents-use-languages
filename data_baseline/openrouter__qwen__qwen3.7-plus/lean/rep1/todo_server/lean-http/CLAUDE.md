# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`lean-http` is a Pure Lean 4 HTTP/1.1 server library inspired by Go's [chi](https://github.com/go-chi/chi). No C FFI or external dependencies — only Lean 4 standard library. Uses `Std.Internal.IO.Async.TCP` for networking.

## Build Commands

- `lake build` — build the library only (target: `LeanHTTP`)
- `lake build example` — build the example HTTP server
- `lake build tests` — build the test suite
- `.lake/build/bin/tests` — run tests after building
- `.lake/build/bin/example` — run the example server on port 8080

## Language & Toolchain

- Lean 4 v4.27.0 (`lean-toolchain`: `leanprover/lean4:v4.27.0`)
- No external dependencies

## Architecture

### Module Dependency Graph

```
Server → Router → Middleware → Response → Types
                → Context   → Types
         Router → Response  → Types
Parser ──────────────────────→ Types
Cookie ──────────────────────→ Types
```

### Key Modules

- **Types.lean** — Core types: `HttpMethod`, `HttpRequest` (with `context` field for middleware data passing), `HttpResponse`, `Handler` (`HttpRequest → IO HttpResponse`), `Middleware` (`Handler → Handler`)
- **Parser.lean** — HTTP/1.1 request parser (`ByteArray → Option HttpRequest`). Parses request line, headers, query params, body (via Content-Length). Includes URL percent-decoding, path normalization (traversal prevention), and configurable size limits via `ParseConfig`
- **Router.lean** — Trie-based router with `{param}` URL patterns and `/*` wildcard catch-all. Uses a flat node pool (`Array NodeData` with index-based references) to avoid Lean's nested inductive type restrictions. Chi-style API: `get`, `post`, `put`, `delete`, `route` (prefix grouping), `dispatch`. Features: HEAD→GET fallback, 405 Method Not Allowed with `Allow` header, trailing slash normalization, `Router.routes` and `Router.printRoutes` for debug route listing
- **Middleware.lean** — `loggerMiddleware` (timing), `recovererMiddleware` (exception → 500), `corsMiddleware` (configurable CORS with preflight), `requestIdMiddleware` (auto-generates X-Request-Id), `rateLimitMiddleware` (fixed-window rate limiter, returns `IO Middleware`), `timeoutMiddleware` (504 on slow handlers)
- **Server.lean** — TCP server using `Std.Internal.IO.Async.TCP.Socket`. Concurrent connection handling via `IO.asTask`. Features: `ServerConfig` (port, maxConnections, readTimeoutMs, keepAliveTimeoutMs, maxHeaderSize, maxBodySize), `Server` handle for graceful shutdown, connection limits (503 on excess), read timeout (408 on slow clients), keep-alive (connection reuse with idle timeout), HEAD body stripping. `Router.listen` for simple use, `Router.serve` for full control
- **Context.lean** — `HttpRequest.param`, `HttpRequest.paramNat`, `HttpRequest.queryParam`, `HttpRequest.header` (case-insensitive), `HttpRequest.contentType`, `HttpRequest.userAgent`, `HttpRequest.ctx`/`HttpRequest.withCtx` (middleware context access)
- **Response.lean** — Response builders (`ok`, `json`, `html`, `text`, `notFound`, `redirect`, `movedPermanently`, `found`, `temporaryRedirect`, `permanentRedirect`, `requestTimeout`, `payloadTooLarge`, `serviceUnavailable`, etc.) and `toByteArray` serializer
- **Cookie.lean** — `HttpRequest.cookie` (parse Cookie header), `HttpResponse.setCookie` (build Set-Cookie with `CookieOptions`: path, domain, maxAge, secure, httpOnly, sameSite)

### Design Decisions

- **No HTTPS/TLS** — By design. TLS termination is handled by a load balancer or reverse proxy (nginx, Caddy, ALB, etc.) in front of the application server
- **Keep-Alive by default** — TCP connections are reused. `Connection: close` only sent when client requests it. Idle timeout configurable via `keepAliveTimeoutMs`
- **Flat node pool router** — Avoids Lean 4 kernel nested inductive type issues with `IO.Ref` in recursive structures

### Lean 4 v4.27.0 Pitfalls

- `Std.HashMap.empty` doesn't exist as a constant — use `{}` with type annotation
- Structures containing `IO.Ref` of themselves (or via `Array`/`Prod`) cause nested inductive errors — use index-based node pools instead
- `prefix` is a keyword — cannot be used as a field name
- `String.containsSubstr`, `String.get!`, `String.mk`, `String.trim`, `String.trimRight` are deprecated — use alternatives (`String.ofList`, `String.trimAscii`, etc.)
- TCP async operations (`send`, `recv?`, `accept`, `shutdown`) return `Async T` — always call `.block` to get `IO T`
- `IPv4Addr` constructor takes a single `UInt32` (use `⟨0⟩` for 0.0.0.0)
- `IO.asTask` spawns concurrent tasks; use for per-connection handling
- `IO.sleep` takes `UInt32` milliseconds
- Infinite loops need `partial def` (not `let rec` in do blocks)
