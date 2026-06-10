# lean-http Production Readiness Roadmap

## Current State

HTTP/1.1 server with chi-style trie router, middleware chain, request parser, and response builder. Concurrent connection handling with keep-alive, security hardening, full middleware suite (CORS, RequestID, rate limiting, timeout, context), cookie/redirect/header helpers, route debugging. P0-P3 complete.

---

## P0: Security & Stability (Must-have) ✅

### 1. Concurrent Connection Handling ✅
### 2. Request Size Limits ✅
### 3. Read Timeout ✅
### 4. URL Decoding ✅
### 5. Path Normalization ✅
### 6. Graceful Shutdown ✅
### 7. Connection Limit ✅

---

## P1: HTTP Protocol Compliance ✅

### 8. Keep-Alive ✅
### 9. Chunked Transfer-Encoding — deferred (not needed for most use cases)
### 10. HEAD Method ✅
### 11. 405 Method Not Allowed ✅
### 12. Content-Length Validation ✅
### 13. Wildcard Routes ✅
### 14. Trailing Slash Handling ✅

---

## P2: Developer Experience ✅

### 15. CORS Middleware ✅
### 16. RequestID Middleware ✅
### 17. Redirect Helpers (301/302/307/308) ✅
### 18. Cookie Read/Write ✅
### 19. Header Access Helpers (`req.header "Content-Type"`) ✅
### 20. HTML/Text Response Helpers ✅
### 21. Route Priority Documentation — deferred
### 22. Integration Tests (actual TCP) — deferred

---

## P3: Maturity ✅

### 23. Gzip Compression Middleware — deferred (requires C FFI for deflate)
### 24. Rate Limiting Middleware ✅
### 25. Timeout Middleware ✅
### 26. Streaming Responses — deferred (requires chunked TE)
### 27. Middleware Context (request-scoped data passing) ✅
### 28. Route List Dump (debug) ✅
