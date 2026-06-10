#!/bin/bash
set -euo pipefail
PORT=8099
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=cookies.txt
rm -f "$COOKIE_JAR"

jqbin=$(command -v jq || true)
function pretty() { if [[ -n "$jqbin" ]]; then jq -S .; else cat; fi }

function curlj() {
  local method="$1"; shift
  local path="$1"; shift
  if [[ "$method" == "DELETE" ]]; then
    curl -sS -i -X "$method" "$BASE$path" -b "$COOKIE_JAR" -c "$COOKIE_JAR"
  else
    curl -sS -i -X "$method" "$BASE$path" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' "$@"
  fi
}

function assert_status() {
  local expected="$1"; shift
  local got=$(grep -m1 -oE "HTTP/[0-9.]+ [0-9]+" <<< "$1" | awk '{print $2}')
  if [[ "$got" != "$expected" ]]; then
    echo "Expected status $expected, got $got" >&2
    echo "$1" >&2
    exit 1
  fi
}

echo "1) Register"
resp=$(curlj POST /register --data '{"username":"alice","password":"password123"}')
assert_status 201 "$resp"

# Duplicate register
resp=$(curlj POST /register --data '{"username":"alice","password":"password123"}')
assert_status 409 "$resp"

echo "2) Login"
resp=$(curlj POST /login --data '{"username":"alice","password":"password123"}')
assert_status 200 "$resp"

# Me
echo "3) Me"
resp=$(curlj GET /me)
assert_status 200 "$resp"

# Change password
echo "4) Change password"
resp=$(curlj PUT /password --data '{"old_password":"password123","new_password":"newpass123"}')
assert_status 200 "$resp"

# Logout
echo "5) Logout"
resp=$(curlj POST /logout)
assert_status 200 "$resp"

# Access after logout -> 401
echo "6) Access after logout"
resp=$(curlj GET /me || true)
assert_status 401 "$resp"

# Login with new password
echo "7) Login again"
resp=$(curlj POST /login --data '{"username":"alice","password":"newpass123"}')
assert_status 200 "$resp"

# Todos: list empty
echo "8) Todos list empty"
resp=$(curlj GET /todos)
assert_status 200 "$resp"

# Create todo
echo "9) Create todo"
resp=$(curlj POST /todos --data '{"title":"Buy milk","description":"2%"}')
assert_status 201 "$resp"

# Create second todo with default description
resp=$(curlj POST /todos --data '{"title":"Read book"}')
assert_status 201 "$resp"

# List todos should be 2
echo "10) List todos 2"
resp=$(curlj GET /todos)
assert_status 200 "$resp"

# Get todo 1
echo "11) Get todo 1"
resp=$(curlj GET /todos/1)
assert_status 200 "$resp"

# Update todo 1 partial
echo "12) Update todo 1"
resp=$(curlj PUT /todos/1 --data '{"completed":true}')
assert_status 200 "$resp"

# Delete todo 2
echo "13) Delete todo 2"
resp=$(curlj DELETE /todos/2)
assert_status 204 "$resp"

# Get deleted todo -> 404
echo "14) Get deleted todo"
resp=$(curlj GET /todos/2 || true)
assert_status 404 "$resp"

echo "15) Ensure another user cannot access"
# Register bob
resp=$(curlj POST /register --data '{"username":"bob","password":"password123"}')
assert_status 201 "$resp"
# Login bob
resp=$(curlj POST /login --data '{"username":"bob","password":"password123"}')
assert_status 200 "$resp"
# Try to access alice's todo 1 -> 404
resp=$(curlj GET /todos/1 || true)
assert_status 404 "$resp"
# Try to delete alice's todo 1 -> 404
resp=$(curlj DELETE /todos/1 || true)
assert_status 404 "$resp"

# Invalid title on create
echo "16) Invalid create title"
resp=$(curlj POST /todos --data '{"title":""}')
assert_status 400 "$resp"

# Switch back to alice
resp=$(curlj POST /login --data '{"username":"alice","password":"newpass123"}')
assert_status 200 "$resp"

# Invalid update empty title on own todo
echo "17) Invalid update empty title"
resp=$(curlj PUT /todos/1 --data '{"title":""}' || true)
assert_status 400 "$resp"

echo "All tests passed"