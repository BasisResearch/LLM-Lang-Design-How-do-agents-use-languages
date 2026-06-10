#!/bin/sh
set -e
PORT=3456
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; if [ -n "$SERVER_PID" ]; then kill $SERVER_PID || true; fi }
trap cleanup EXIT

./run.sh --port $PORT &
SERVER_PID=$!
sleep 0.5

request() {
  method="$1"; path="$2"; data="$3"; expect_code="$4"; has_body="$5";
  if [ "$method" = "DELETE" ]; then
    # For DELETE, expect no body; but we still use curl to capture status
    code=$(curl -sS -o /tmp/resp.$$ -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X DELETE "http://127.0.0.1:$PORT$path")
    if [ "$code" != "$expect_code" ]; then echo "Expected $expect_code got $code for $method $path"; cat /tmp/resp.$$; exit 1; fi
    rm -f /tmp/resp.$$
    return
  fi
  if [ -n "$data" ]; then
    code=$(curl -sS -o /tmp/resp.$$ -w "%{http_code}" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X "$method" --data "$data" "http://127.0.0.1:$PORT$path")
  else
    code=$(curl -sS -o /tmp/resp.$$ -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X "$method" "http://127.0.0.1:$PORT$path")
  fi
  if [ "$code" != "$expect_code" ]; then echo "Expected $expect_code got $code for $method $path"; cat /tmp/resp.$$; exit 1; fi
  if [ "$has_body" = "1" ]; then cat /tmp/resp.$$; fi
  rm -f /tmp/resp.$$
}

echo "Register user..."
request POST /register '{"username":"user_1","password":"supersecret"}' 201 1 >/tmp/u.json

USER_ID=$(cat /tmp/u.json | sed -E 's/.*"id":([0-9]+).*/\1/')

# login
echo "Login..."
request POST /login '{"username":"user_1","password":"supersecret"}' 200 1 >/tmp/me.json

# me
echo "Me..."
request GET /me '' 200 1 >/tmp/me.json

# password change
echo "Change password..."
request PUT /password '{"old_password":"supersecret","new_password":"newsecret1"}' 200 1 >/dev/null

# logout
echo "Logout..."
request POST /logout '' 200 1 >/dev/null

# Ensure auth required after logout
echo "Check auth after logout..."
request GET /me '' 401 1 >/dev/null

# login again with new password
echo "Login again..."
request POST /login '{"username":"user_1","password":"newsecret1"}' 200 1 >/dev/null

# create todos
echo "Create todo 1..."
request POST /todos '{"title":"First","description":"Desc1"}' 201 1 >/tmp/t1.json
id1=$(cat /tmp/t1.json | sed -E 's/.*"id":([0-9]+).*/\1/')

echo "Create todo 2..."
request POST /todos '{"title":"Second"}' 201 1 >/tmp/t2.json
id2=$(cat /tmp/t2.json | sed -E 's/.*"id":([0-9]+).*/\1/')

# list todos
echo "List todos..."
request GET /todos '' 200 1 >/tmp/list.json

# get todo
echo "Get todo 1..."
request GET /todos/$id1 '' 200 1 >/dev/null

# update todo (partial)
echo "Update todo 2..."
request PUT /todos/$id2 '{"completed":true,"description":"Updated"}' 200 1 >/dev/null

# delete todo
echo "Delete todo 1..."
request DELETE /todos/$id1 '' 204 0

# verify 404 after delete
echo "Get deleted todo..."
request GET /todos/$id1 '' 404 1 >/dev/null

echo "All tests passed"
