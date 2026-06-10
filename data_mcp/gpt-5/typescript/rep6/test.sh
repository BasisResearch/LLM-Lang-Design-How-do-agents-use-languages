#!/usr/bin/env bash
set -euo pipefail
PORT=3187
ROOT="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
SVR_PID=$!
# Wait for server to start
for i in {1..50}; do
  if curl -sS "$ROOT/me" -b "$COOKIE_JAR" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# Helper to require status code
req() {
  local method=$1
  local path=$2
  shift 2
  curl -sS -o /tmp/resp.json -w "%{http_code}" -X "$method" "$ROOT$path" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

# 1. Unauthorized access check
code=$(req GET /me)
[[ "$code" == "401" ]] || { echo "Expected 401 for /me, got $code"; kill $SVR_PID; exit 1; }

# 2. Register
code=$(req POST /register --data '{"username":"alice","password":"password123"}')
[[ "$code" == "201" ]] || { echo "Register failed: $code"; kill $SVR_PID; exit 1; }

# 3. Login
code=$(req POST /login --data '{"username":"alice","password":"password123"}')
[[ "$code" == "200" ]] || { echo "Login failed: $code"; kill $SVR_PID; exit 1; }

# 4. Me
code=$(req GET /me)
[[ "$code" == "200" ]] || { echo "/me failed: $code"; kill $SVR_PID; exit 1; }

# 5. Create todos
code=$(req POST /todos --data '{"title":"Task1","description":"Desc1"}')
[[ "$code" == "201" ]] || { echo "Create todo1 failed: $code"; kill $SVR_PID; exit 1; }
code=$(req POST /todos --data '{"title":"Task2"}')
[[ "$code" == "201" ]] || { echo "Create todo2 failed: $code"; kill $SVR_PID; exit 1; }

# 6. List todos
code=$(req GET /todos)
[[ "$code" == "200" ]] || { echo "List todos failed: $code"; kill $SVR_PID; exit 1; }

# 7. Get specific todo
code=$(req GET /todos/1)
[[ "$code" == "200" ]] || { echo "Get todo 1 failed: $code"; kill $SVR_PID; exit 1; }

# 8. Update todo partially
code=$(req PUT /todos/1 --data '{"completed":true}')
[[ "$code" == "200" ]] || { echo "Update todo 1 failed: $code"; kill $SVR_PID; exit 1; }

# 9. Delete todo
code=$(req DELETE /todos/2)
[[ "$code" == "204" ]] || { echo "Delete todo 2 failed: $code"; kill $SVR_PID; exit 1; }

# 10. Password change and re-auth
code=$(req PUT /password --data '{"old_password":"password123","new_password":"newpass123"}')
[[ "$code" == "200" ]] || { echo "Password change failed: $code"; kill $SVR_PID; exit 1; }

# 11. Logout
code=$(req POST /logout)
[[ "$code" == "200" ]] || { echo "Logout failed: $code"; kill $SVR_PID; exit 1; }

# 12. Access after logout should be 401
code=$(req GET /me)
[[ "$code" == "401" ]] || { echo "Post-logout /me expected 401, got $code"; kill $SVR_PID; exit 1; }

# 13. Login with new password works
code=$(req POST /login --data '{"username":"alice","password":"newpass123"}')
[[ "$code" == "200" ]] || { echo "Re-login failed: $code"; kill $SVR_PID; exit 1; }

# 14. Try accessing a non-existent todo
code=$(req GET /todos/999)
[[ "$code" == "404" ]] || { echo "Expected 404 for missing todo, got $code"; kill $SVR_PID; exit 1; }

# 15. Validation errors
code=$(req POST /todos --data '{"title":""}')
[[ "$code" == "400" ]] || { echo "Expected 400 for empty title, got $code"; kill $SVR_PID; exit 1; }

# 16. Username uniqueness
code=$(req POST /register --data '{"username":"alice","password":"anotherpass"}')
[[ "$code" == "409" ]] || { echo "Expected 409 for duplicate username, got $code"; kill $SVR_PID; exit 1; }

# Shutdown
kill $SVR_PID
wait $SVR_PID 2>/dev/null || true

echo "All tests passed"
