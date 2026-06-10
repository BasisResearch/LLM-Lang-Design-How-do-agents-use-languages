#!/usr/bin/env bash
set -euo pipefail
PORT=8123
# Kill any existing server on this port to avoid stale state
if command -v lsof >/dev/null 2>&1; then
  pids=$(lsof -tiTCP:$PORT -sTCP:LISTEN || true)
  if [[ -n "${pids:-}" ]]; then kill $pids || true; fi
fi

./run.sh --port "$PORT" &
PID=$!
base=http://127.0.0.1:$PORT
cookiejar=$(mktemp)
trap 'kill $PID || true; rm -f "$cookiejar" "$cookiejar2"' EXIT
hdrs=(-H 'Content-Type: application/json' -sS -D /dev/stderr)

# wait for server readiness
for i in {1..60}; do
  code=$(curl -sS -o /dev/null "$base/me" -w '%{http_code}' || true)
  if [[ "$code" =~ ^(401|200|404)$ ]]; then break; fi
  sleep 0.2
done

uname="user_$RANDOM$$"
pass="password123"

# Expect JSON Content-Type helper
check_json_ct() {
  local url=$1; shift
  local headers
  headers=$(curl -o /dev/null -sS -D - "$@" "$url") || return 1
  local ct
  ct=$(printf '%s' "$headers" | tr '[:upper:]' '[:lower:]' | awk '/^content-type:/ {print $0; exit}')
  if [[ $ct == *"application/json"* ]]; then
    return 0
  else
    echo "Bad content-type for $url: $ct" >&2
    return 1
  fi
}

# Register
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body.json \
  "${base}/register" -X POST "${hdrs[@]}" \
  --data "{\"username\":\"$uname\",\"password\":\"$pass\"}")
code=${resp##*$'\n'}
[[ $code == 201 ]] || { echo "Register failed: $resp"; exit 1; }
check_json_ct "${base}/register" -X POST "${hdrs[@]}" --data '{"username":"x_1","password":"password123"}' || true

# Login
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body.json \
  "${base}/login" -X POST "${hdrs[@]}" \
  --data "{\"username\":\"$uname\",\"password\":\"$pass\"}")
code=${resp##*$'\n'}
[[ $code == 200 ]] || { echo "Login failed: $resp"; exit 1; }

# /me
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body.json \
  "${base}/me" -X GET)
code=${resp##*$'\n'}
[[ $code == 200 ]] || { echo "/me failed: $resp"; exit 1; }

# Change password
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body.json \
  "${base}/password" -X PUT "${hdrs[@]}" \
  --data '{"old_password":"password123","new_password":"newpassword123"}')
code=${resp##*$'\n'}
[[ $code == 200 ]] || { echo "Password change failed: $resp"; exit 1; }

# Create todo
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body1.json \
  "${base}/todos" -X POST "${hdrs[@]}" \
  --data '{"title":"Task A","description":"Desc"}')
code=${resp##*$'\n'}
[[ $code == 201 ]] || { echo "Create todo failed: $resp"; exit 1; }

# List todos
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body2.json \
  "${base}/todos" -X GET)
code=${resp##*$'\n'}
[[ $code == 200 ]] || { echo "List todos failed: $resp"; exit 1; }

id=$(jq -r '.[0].id' /tmp/body2.json)

# Get todo
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body3.json \
  "${base}/todos/$id" -X GET)
code=${resp##*$'\n'}
[[ $code == 200 ]] || { echo "Get todo failed: $resp"; exit 1; }

# Update todo
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body4.json \
  "${base}/todos/$id" -X PUT "${hdrs[@]}" \
  --data '{"completed":true,"description":"Updated"}')
code=${resp##*$'\n'}
[[ $code == 200 ]] || { echo "Update todo failed: $resp"; exit 1; }

# Second user to test 404 on other user's todo
cookiejar2=$(mktemp)
uname2="user_$RANDOM$$"
pass2="password234"
curl -b "$cookiejar2" -c "$cookiejar2" -sS -o /dev/null \
  "${base}/register" -X POST "${hdrs[@]}" \
  --data "{\"username\":\"$uname2\",\"password\":\"$pass2\"}"
curl -b "$cookiejar2" -c "$cookiejar2" -sS -o /dev/null \
  "${base}/login" -X POST "${hdrs[@]}" \
  --data "{\"username\":\"$uname2\",\"password\":\"$pass2\"}"
code=$(curl -b "$cookiejar2" -c "$cookiejar2" -sS -o /dev/null -w '%{http_code}' \
  "${base}/todos/$id" -X GET)
[[ $code == 404 ]] || { echo "Expected 404 for other user's todo, got: $code"; exit 1; }

# Delete todo
code=$(curl -b "$cookiejar" -c "$cookiejar" -sS -o /dev/null -w '%{http_code}' \
  "${base}/todos/$id" -X DELETE)
[[ $code == 204 ]] || { echo "Delete todo failed: $code"; exit 1; }

# Logout
resp=$(curl -b "$cookiejar" -c "$cookiejar" -sS -w '\n%{http_code}' -o /tmp/body5.json \
  "${base}/logout" -X POST)
code=${resp##*$'\n'}
[[ $code == 200 ]] || { echo "Logout failed: $resp"; exit 1; }

# Ensure session invalidated
code=$(curl -b "$cookiejar" -c "$cookiejar" -sS -o /tmp/body6.json -w '%{http_code}' \
  "${base}/me" -X GET)
[[ $code == 401 ]] || { echo "Expected 401 after logout, got: $code"; cat /tmp/body6.json; exit 1; }

echo "All tests passed"
