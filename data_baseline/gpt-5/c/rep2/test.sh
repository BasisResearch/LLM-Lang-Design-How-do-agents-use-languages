#!/usr/bin/env bash
set -euo pipefail
PORT=8087
COOKIE_JAR=$(mktemp)

# Build and start server
./run.sh --port ${PORT} &
SERVER_PID=$!
trap 'kill ${SERVER_PID} >/dev/null 2>&1 || true; rm -f ${COOKIE_JAR}' EXIT

# Wait for server to start
sleep 1

base() { echo -n "http://127.0.0.1:${PORT}$1"; }

jq_body() { echo "$1" | jq -c .; }

status_body() {
  status=$(cat status.txt)
  body=$(cat body.txt)
  echo "STATUS=$status BODY=$body"
}

request() {
  method=$1; path=$2; data=${3-}
  if [[ -n "${data}" ]]; then
    curl -sS -X "$method" -H 'Content-Type: application/json' -b ${COOKIE_JAR} -c ${COOKIE_JAR} -d "$data" -w '%{http_code}' "$(base "$path")" -o body.txt > status.txt
  else
    curl -sS -X "$method" -H 'Content-Type: application/json' -b ${COOKIE_JAR} -c ${COOKIE_JAR} -w '%{http_code}' "$(base "$path")" -o body.txt > status.txt
  fi
}

# 1. Register
request POST /register '{"username":"user_one","password":"password1"}'
[[ $(cat status.txt) == "201" ]] || { echo "Register failed"; status_body; exit 1; }

echo "Register OK"

# Duplicate username
request POST /register '{"username":"user_one","password":"password1"}'
[[ $(cat status.txt) == "409" ]] || { echo "Duplicate username should 409"; status_body; exit 1; }

echo "Register duplicate handled"

# 2. Login
request POST /login '{"username":"user_one","password":"password1"}'
[[ $(cat status.txt) == "200" ]] || { echo "Login failed"; status_body; exit 1; }

echo "Login OK"

# 3. /me
request GET /me
[[ $(cat status.txt) == "200" ]] || { echo "/me failed"; status_body; exit 1; }

echo "/me OK"

# 4. Change password
request PUT /password '{"old_password":"password1","new_password":"password2"}'
[[ $(cat status.txt) == "200" ]] || { echo "Password change failed"; status_body; exit 1; }

echo "Password change OK"

# 5. Logout
request POST /logout
[[ $(cat status.txt) == "200" ]] || { echo "Logout failed"; status_body; exit 1; }

echo "Logout OK"

# 6. /me should now 401
request GET /me
[[ $(cat status.txt) == "401" ]] || { echo "Post-logout /me should 401"; status_body; exit 1; }

echo "Post-logout 401 OK"

# 7. Login with new password
request POST /login '{"username":"user_one","password":"password2"}'
[[ $(cat status.txt) == "200" ]] || { echo "Re-login failed"; status_body; exit 1; }

echo "Re-login OK"

# 8. Create todos
request POST /todos '{"title":"Task A","description":"First"}'
[[ $(cat status.txt) == "201" ]] || { echo "Create todo A failed"; status_body; exit 1; }
A_ID=$(jq -r '.id' body.txt)

request POST /todos '{"title":"Task B"}'
[[ $(cat status.txt) == "201" ]] || { echo "Create todo B failed"; status_body; exit 1; }
B_ID=$(jq -r '.id' body.txt)

# 9. List todos
request GET /todos
[[ $(cat status.txt) == "200" ]] || { echo "List todos failed"; status_body; exit 1; }
COUNT=$(jq 'length' body.txt)
[[ "$COUNT" -ge 2 ]] || { echo "Expected at least 2 todos"; exit 1; }

# 10. Get single todo
request GET /todos/${A_ID}
[[ $(cat status.txt) == "200" ]] || { echo "Get todo failed"; status_body; exit 1; }

# 11. Update todo partial
request PUT /todos/${A_ID} '{"completed":true}'
[[ $(cat status.txt) == "200" ]] || { echo "Update todo failed"; status_body; exit 1; }

# 12. Delete todo
request DELETE /todos/${B_ID}
[[ $(cat status.txt) == "204" ]] || { echo "Delete todo failed"; status_body; exit 1; }

echo "All tests passed"
kill ${SERVER_PID}
wait ${SERVER_PID} || true
rm -f ${COOKIE_JAR} body.txt status.txt
