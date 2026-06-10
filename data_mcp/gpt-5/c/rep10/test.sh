#!/usr/bin/env bash
set -euo pipefail
PORT=18222
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

echo "Testing register (success)" >&2
curl -sS -D /tmp/headers1 -o /tmp/body1 -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}'
cat /tmp/body1

if ! grep -q '201' /tmp/headers1; then echo "Register failed" >&2; exit 1; fi

# duplicate username
set +e
HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
set -e
if [[ "$HTTP" != "409" ]]; then echo "Expected 409 for duplicate username" >&2; exit 1; fi

# login
echo "Testing login" >&2
curl -sS -D /tmp/headers2 -o /tmp/body2 -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}'
cat /tmp/body2
if ! grep -qi '^set-cookie: session_id=' /tmp/headers2; then echo "No Set-Cookie" >&2; exit 1; fi

# me
echo "Testing /me" >&2
curl -sS -b "$COOKIE_JAR" "$BASE/me"

# password change
echo "Testing password change" >&2
curl -sS -b "$COOKIE_JAR" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword456"}'

# logout
echo "Testing logout" >&2
curl -sS -b "$COOKIE_JAR" -X POST "$BASE/logout"

# me should fail after logout
set +e
HTTP=$(curl -sS -o /dev/null -b "$COOKIE_JAR" -w '%{http_code}' "$BASE/me")
set -e
if [[ "$HTTP" != "401" ]]; then echo "Expected 401 after logout" >&2; exit 1; fi

# login with new password
curl -sS -D /tmp/headers3 -o /tmp/body3 -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"newpassword456"}'

# todos empty list
echo "Testing GET /todos" >&2
curl -sS -b "$COOKIE_JAR" "$BASE/todos"

# create todo
echo "Testing POST /todos" >&2
curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"desc"}' "$BASE/todos" -X POST

# create another
curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 2"}' "$BASE/todos" -X POST

# list
curl -sS -b "$COOKIE_JAR" "$BASE/todos"

# get id 1
curl -sS -b "$COOKIE_JAR" "$BASE/todos/1"

# partial update
curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"completed":true}' -X PUT "$BASE/todos/1"

# get again
curl -sS -b "$COOKIE_JAR" "$BASE/todos/1"

# delete
curl -sS -b "$COOKIE_JAR" -X DELETE "$BASE/todos/1" -D /tmp/headers_del -o /tmp/body_del || true
if ! grep -q '^HTTP/1.1 204' /tmp/headers_del; then echo "Expected 204 on delete" >&2; exit 1; fi
if [[ -s /tmp/body_del ]]; then echo "Expected empty body on delete" >&2; exit 1; fi

# get should 404
set +e
HTTP=$(curl -sS -o /dev/null -b "$COOKIE_JAR" -w '%{http_code}' "$BASE/todos/1")
set -e
if [[ "$HTTP" != "404" ]]; then echo "Expected 404 after delete" >&2; exit 1; fi

echo "All tests passed" >&2
