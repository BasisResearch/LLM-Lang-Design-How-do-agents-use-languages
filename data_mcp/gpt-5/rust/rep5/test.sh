#!/usr/bin/env bash
set -euo pipefail
PORT=${1:-8081}
BASE="http://127.0.0.1:${PORT}"
CURL=(curl -s -S -D /tmp/headers.txt -o /tmp/body.txt)

# Helper to perform a request
request() {
  local method="$1" path="$2" data="${3:-}" cookie="${4:-}"
  local args=("-X" "$method" "$BASE$path" -H 'Content-Type: application/json')
  if [[ -n "$data" ]]; then args+=(--data "$data"); fi
  if [[ -n "$cookie" ]]; then args+=(-H "Cookie: session_id=$cookie"); fi
  "${CURL[@]}" "${args[@]}"
  local code
  code=$(awk 'toupper($1)=="HTTP/1.1"||toupper($1)=="HTTP/2"{print $2; exit}' /tmp/headers.txt)
  echo "$code"
}

# Start fresh
rm -f /tmp/headers.txt /tmp/body.txt

# 1) Register
code=$(request POST /register '{"username":"alice_1","password":"password123"}')
[[ "$code" == "201" ]]
cat /tmp/body.txt

# 2) Login
code=$(request POST /login '{"username":"alice_1","password":"password123"}')
[[ "$code" == "200" ]]
session=$(grep -i '^Set-Cookie:' /tmp/headers.txt | sed -n 's/.*session_id=\([^;]*\).*/\1/p')
[[ -n "$session" ]]

# 3) /me
code=$(request GET /me '' "$session")
[[ "$code" == "200" ]]

# 4) change password wrong old
code=$(request PUT /password '{"old_password":"bad","new_password":"newpassword"}' "$session")
[[ "$code" == "401" ]]

# 5) change password ok
code=$(request PUT /password '{"old_password":"password123","new_password":"newpassword"}' "$session")
[[ "$code" == "200" ]]

# 6) create todos
code=$(request POST /todos '{"title":"Task1","description":"Do A"}' "$session"); [[ "$code" == "201" ]] || { echo create1 failed; exit 1; }
code=$(request POST /todos '{"title":"Task2"}' "$session"); [[ "$code" == "201" ]] || { echo create2 failed; exit 1; }

# 7) list todos
code=$(request GET /todos '' "$session"); [[ "$code" == "200" ]]

# Grab first todo id
first_id=$(jq -r '.[0].id' /tmp/body.txt)

# 8) get specific todo
code=$(request GET "/todos/$first_id" '' "$session"); [[ "$code" == "200" ]]

# 9) update todo
code=$(request PUT "/todos/$first_id" '{"completed":true}' "$session"); [[ "$code" == "200" ]]

# 10) delete todo
code=$(request DELETE "/todos/$first_id" '' "$session"); [[ "$code" == "204" ]]

# 11) logout
code=$(request POST /logout '' "$session"); [[ "$code" == "200" ]]

# 12) ensure session invalid
code=$(request GET /me '' "$session"); [[ "$code" == "401" ]]

echo "All tests passed"
