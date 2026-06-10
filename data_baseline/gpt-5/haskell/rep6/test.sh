#!/usr/bin/env bash
set -euo pipefail
PORT=${1:-8111}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

request() {
  method="$1"; url="$2"; shift 2
  curl -sS -X "$method" "$url" "$@"
}

json_post() {
  url="$1"; shift
  curl -sS -X POST "$url" -H 'Content-Type: application/json' --data-binary @- <<'JSON'
{"username":"user1","password":"password123"}
JSON
}

echo "Register user1"
json_post "$BASE/register" | cat

# Duplicate register should 409
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/register" -H 'Content-Type: application/json' --data-binary @- <<'JSON'
{"username":"user1","password":"password123"}
JSON
)
[[ "$code" == "409" ]] || { echo "Expected 409, got $code"; exit 1; }

echo "Login"
curl -sS -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' --data-binary @- <<'JSON'
{"username":"user1","password":"password123"}
JSON

# GET /me
echo "Me"
curl -sS -b "$COOKIE_JAR" "$BASE/me" | cat

# Change password
echo "Change password"
curl -sS -b "$COOKIE_JAR" -X PUT "$BASE/password" -H 'Content-Type: application/json' --data-binary @- <<'JSON'
{"old_password":"password123","new_password":"newpass123"}
JSON

# Logout
echo "Logout"
curl -sS -b "$COOKIE_JAR" -X POST "$BASE/logout" | cat

# Access protected after logout -> 401
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$BASE/me")
[[ "$code" == "401" ]] || { echo "Expected 401 after logout, got $code"; exit 1; }

# Login with new password
echo "Re-login"
curl -sS -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' --data-binary @- <<'JSON'
{"username":"user1","password":"newpass123"}
JSON

# Create todo 1
echo "Create todo 1"
curl -sS -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' --data-binary @- <<'JSON'
{"title":"T1","description":"D1"}
JSON

# Create todo 2
echo "Create todo 2"
curl -sS -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' --data-binary @- <<'JSON'
{"title":"T2"}
JSON

# List todos
echo "List"
curl -sS -b "$COOKIE_JAR" "$BASE/todos" | cat

# Get todo 1
echo "Get 1"
curl -sS -b "$COOKIE_JAR" "$BASE/todos/1" | cat

# Update todo 1
echo "Update 1"
curl -sS -b "$COOKIE_JAR" -X PUT "$BASE/todos/1" -H 'Content-Type: application/json' --data-binary @- <<'JSON'
{"completed":true, "description":"D1b"}
JSON

# Delete todo 2
echo "Delete 2"
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X DELETE "$BASE/todos/2")
[[ "$code" == "204" ]] || { echo "Expected 204, got $code"; exit 1; }

# Ensure 404 for deleted
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "$BASE/todos/2")
[[ "$code" == "404" ]] || { echo "Expected 404, got $code"; exit 1; }

echo "All tests passed"
