#!/usr/bin/env bash
set -euo pipefail
PORT=4545
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
"$ROOT/run.sh" --port "$PORT" &
PID=$!
trap 'kill $PID || true' EXIT
sleep 5
base="http://0.0.0.0:$PORT"

jar=$(mktemp)

expect() { code=$1; shift; cmd=(curl -sS -o /tmp/resp.json -w "%{http_code}" "$@"); rc=$("${cmd[@]}"); if [[ "$rc" != "$code" ]]; then echo "Expected $code got $rc for: $*"; cat /tmp/resp.json; exit 1; fi; cat /tmp/resp.json; }

# 1) Register
resp=$(expect 201 -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$base/register")
[[ "$resp" == *'"username":"alice"'* ]]

# 2) Login
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' -c "$jar" "$base/login"); [[ "$code" == "200" ]] || { cat /tmp/resp.json; exit 1; }

# 3) /me
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -b "$jar" "$base/me"); [[ "$code" == "200" ]] || { cat /tmp/resp.json; exit 1; }

# 4) Change password
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -b "$jar" -d '{"old_password":"password123","new_password":"password456"}' "$base/password"); [[ "$code" == "200" ]] || { cat /tmp/resp.json; exit 1; }

# 5) Create todo
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -X POST -H 'Content-Type: application/json' -b "$jar" -d '{"title":"t1","description":"d1"}' "$base/todos"); [[ "$code" == "201" ]] || { cat /tmp/resp.json; exit 1; }

# 6) List todos
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -b "$jar" "$base/todos"); [[ "$code" == "200" ]] || { cat /tmp/resp.json; exit 1; }

# 7) Get todo 1
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -b "$jar" "$base/todos/1"); [[ "$code" == "200" ]] || { cat /tmp/resp.json; exit 1; }

# 8) Update todo 1
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -b "$jar" -d '{"completed":true}' "$base/todos/1"); [[ "$code" == "200" ]] || { cat /tmp/resp.json; exit 1; }

# 9) Delete todo 1
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -X DELETE -b "$jar" "$base/todos/1"); [[ "$code" == "204" ]] || { cat /tmp/resp.json; exit 1; }

# 10) Logout
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -X POST -b "$jar" "$base/logout"); [[ "$code" == "200" ]] || { cat /tmp/resp.json; exit 1; }

# 11) Access after logout should 401
code=$(curl -sS -o /tmp/resp.json -w "%{http_code}" -b "$jar" "$base/me"); [[ "$code" == "401" ]] || { cat /tmp/resp.json; exit 1; }

echo "All tests passed"
