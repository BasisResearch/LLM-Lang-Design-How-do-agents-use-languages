#!/usr/bin/env bash
set -euo pipefail
PORT=18080
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
rm -f cookies.txt
./run.sh --port "$PORT" &
PID=$!
sleep 1
cleanup(){ kill $PID 2>/dev/null || true; }
trap cleanup EXIT
base="http://127.0.0.1:${PORT}"
check(){
  local name="$1"; shift
  echo "[TEST] $name" >&2
  "$@"
}
req(){
  local method="$1" path="$2" data="${3:-}" expect_code="$4"
  if [[ -n "$data" ]]; then
    code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -X "$method" "$base$path" -H 'Content-Type: application/json' -d "$data" -c cookies.txt -b cookies.txt)
  else
    code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -X "$method" "$base$path" -c cookies.txt -b cookies.txt)
  fi
  cat /tmp/resp.json
  echo
  if [[ "$code" != "$expect_code" ]]; then
    echo "Expected code $expect_code got $code for $method $path" >&2
    exit 1
  fi
}

# Register
req POST /register '{"username":"alice","password":"password123"}' 201
# Login
req POST /login '{"username":"alice","password":"password123"}' 200
# Me
req GET /me '' 200
# Create todo
req POST /todos '{"title":"Task 1","description":"desc"}' 201
# List
req GET /todos '' 200
# Get id 1
req GET /todos/1 '' 200
# Update partial
req PUT /todos/1 '{"completed": true}' 200
# Delete
code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/1" -c cookies.txt -b cookies.txt)
[[ "$code" == "204" ]] || { echo "Expected 204 for delete, got $code"; exit 1; }
# Logout
req POST /logout '' 200
# Me should fail now
req GET /me '' 401

echo "All tests passed"
