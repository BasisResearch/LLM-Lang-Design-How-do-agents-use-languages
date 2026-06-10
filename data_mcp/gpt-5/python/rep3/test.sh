#!/bin/bash
set -euo pipefail

PORT=8099
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR="/tmp/todo_cookies_$$.txt"
SERVER_LOG="/tmp/todo_server_$$.log"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$COOKIE_JAR" "$SERVER_LOG" headers.txt body.json || true
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

echo "Started server PID $SERVER_PID on port $PORT"

# Wait for server to be ready (up to 180 seconds)
READY=0
for i in $(seq 1 360); do
  if curl -sS -o /dev/null "$BASE/register" -m 1; then
    READY=1
    break
  fi
  sleep 0.5
done
if [[ "$READY" -ne 1 ]]; then
  echo "Server did not become ready in time" >&2
  echo "--- Server log ---" >&2
  tail -n +1 "$SERVER_LOG" >&2 || true
  exit 1
fi

echo "Server is ready"

assert_json_response() {
  local method=$1
  local path=$2
  local data=${3:-}
  local expected_status=$4
  local use_cookie=${5:-0}

  rm -f headers.txt body.json
  local args=("-sS" "-D" "headers.txt" "-o" "body.json" "-w" "%{http_code}" "-X" "$method")
  if [[ -n "$data" ]]; then
    args+=("-H" "Content-Type: application/json" "--data" "$data")
  fi
  if [[ "$use_cookie" == 1 ]]; then
    args+=("--cookie" "$COOKIE_JAR" "--cookie-jar" "$COOKIE_JAR")
  fi

  local code
  code=$(curl "${args[@]}" "$BASE$path")
  echo "HTTP $method $path => $code"
  if [[ "$code" != "$expected_status" ]]; then
    echo "Expected status $expected_status, got $code" >&2
    echo "Response body:" >&2
    cat body.json >&2 || true
    echo "Headers:" >&2
    cat headers.txt >&2 || true
    exit 1
  fi

  if [[ "$method" != "DELETE" ]]; then
    # Check content-type is application/json
    if ! grep -iq "^Content-Type: .*application/json" headers.txt; then
      echo "Content-Type is not application/json" >&2
      cat headers.txt >&2
      exit 1
    fi
    # Validate JSON body is parseable
    python3 - <<'PY'
import json,sys
try:
    with open('body.json','rb') as f:
        json.load(f)
except Exception as e:
    print('Invalid JSON body:', e, file=sys.stderr)
    sys.exit(1)
PY
  else
    # Ensure body is empty for DELETE
    if [[ -s body.json ]]; then
      echo "DELETE response should have no body" >&2
      cat body.json >&2
      exit 1
    fi
  fi
}

# Register user
USERNAME="user_$RANDOM"
PASSWORD="password123"
NEWPASSWORD="newpassword456"
assert_json_response POST "/register" "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 201 0

# Duplicate register should 409
assert_json_response POST "/register" "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 409 0

# Login
assert_json_response POST "/login" "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 200 1

# Me
assert_json_response GET "/me" "" 200 1

# Change password
assert_json_response PUT "/password" "{\"old_password\":\"$PASSWORD\",\"new_password\":\"$NEWPASSWORD\"}" 200 1

# Logout
assert_json_response POST "/logout" "" 200 1

# Login with old password should fail
rm -f "$COOKIE_JAR"
code=$(curl -sS -D headers.txt -o body.json -w "%{http_code}" -X POST -H 'Content-Type: application/json' --data "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" "$BASE/login")
if [[ "$code" != "401" ]]; then
  echo "Expected 401 on login with old password, got $code" >&2
  exit 1
fi

# Login with new password should succeed
assert_json_response POST "/login" "{\"username\":\"$USERNAME\",\"password\":\"$NEWPASSWORD\"}" 200 1

# Create todo
assert_json_response POST "/todos" "{\"title\":\"Test Todo\",\"description\":\"First\"}" 201 1
TODO_ID=$(python3 - <<'PY'
import json
with open('body.json','rb') as f:
    print(json.load(f)['id'])
PY
)

echo "Created TODO_ID=$TODO_ID"

# List todos
assert_json_response GET "/todos" "" 200 1

# Get specific todo
assert_json_response GET "/todos/$TODO_ID" "" 200 1

# Update todo partially
assert_json_response PUT "/todos/$TODO_ID" "{\"completed\":true}" 200 1

# Delete todo
assert_json_response DELETE "/todos/$TODO_ID" "" 204 1

# Get deleted todo should 404
code=$(curl -sS -D headers.txt -o body.json -w "%{http_code}" -X GET --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" "$BASE/todos/$TODO_ID")
if [[ "$code" != "404" ]]; then
  echo "Expected 404 for deleted todo, got $code" >&2
  exit 1
fi

# Logout and verify auth is required
assert_json_response POST "/logout" "" 200 1
code=$(curl -sS -D headers.txt -o body.json -w "%{http_code}" -X GET --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR" "$BASE/me")
if [[ "$code" != "401" ]]; then
  echo "Expected 401 for /me after logout, got $code" >&2
  exit 1
fi

echo "All tests passed"