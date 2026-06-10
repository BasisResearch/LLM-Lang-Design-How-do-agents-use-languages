#!/bin/bash
set -euo pipefail
PORT=8081
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

jq_installed() { command -v jq >/dev/null 2>&1; }
if ! jq_installed; then
  echo "Installing jq for tests..." >&2
  sudo apt-get update -y && sudo apt-get install -y jq
fi

# Helper to extract session cookie from response headers using curl cookie jar
curl_json() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -s -S -X "$method" -D /tmp/headers.txt -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data "$data" "$BASE$path"
  else
    curl -s -S -X "$method" -D /tmp/headers.txt -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE$path"
  fi
}

# 1. Register
OUT=$(curl_json POST /register '{"username":"user_1","password":"password123"}')
echo "$OUT" | jq -e '.username=="user_1" and .id==1' >/dev/null

# 1b. Duplicate username should 409
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{"username":"user_1","password":"password123"}' "$BASE/register")
[[ "$CODE" == "409" ]]

# 2. Login
OUT=$(curl_json POST /login '{"username":"user_1","password":"password123"}')
echo "$OUT" | jq -e '.username=="user_1" and .id==1' >/dev/null

# 3. /me
OUT=$(curl_json GET /me)
echo "$OUT" | jq -e '.username=="user_1" and .id==1' >/dev/null

# 4. Create todos
T1=$(curl_json POST /todos '{"title":"Alpha","description":"first"}')
T2=$(curl_json POST /todos '{"title":"Beta"}')
ID1=$(echo "$T1" | jq -r '.id')
ID2=$(echo "$T2" | jq -r '.id')
[[ "$ID1" == "1" && "$ID2" == "2" ]]

# 5. List todos
OUT=$(curl_json GET /todos)
echo "$OUT" | jq -e 'length==2 and .[0].title=="Alpha" and .[1].title=="Beta"' >/dev/null

# 6. Get todo by id
OUT=$(curl_json GET "/todos/$ID1")
echo "$OUT" | jq -e '.id==1 and .title=="Alpha"' >/dev/null

# 7. Update todo partially
OUT=$(curl_json PUT "/todos/$ID2" '{"completed":true}')
echo "$OUT" | jq -e '.completed==true and .title=="Beta"' >/dev/null

# 8. Update title and description
OUT=$(curl_json PUT "/todos/$ID1" '{"title":"Alpha2","description":"first edit"}')
echo "$OUT" | jq -e '.title=="Alpha2" and .description=="first edit"' >/dev/null

# 9. Delete
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X DELETE -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/todos/$ID1")
[[ "$CODE" == "204" ]]

# 10. Ensure not found after delete
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X GET -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/todos/$ID1")
[[ "$CODE" == "404" ]]

# 11. Password change wrong old
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X PUT -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data '{"old_password":"bad","new_password":"newpassword123"}' "$BASE/password")
[[ "$CODE" == "401" ]]

# 12. Password change success
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X PUT -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data '{"old_password":"password123","new_password":"newpassword123"}' "$BASE/password")
[[ "$CODE" == "200" ]]

# 13. Logout
OUT=$(curl_json POST /logout)
echo "$OUT" | jq -e 'type=="object" and length==0' >/dev/null

# 14. After logout, access should be 401
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X GET -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/me")
[[ "$CODE" == "401" ]]

# 15. Re-login with new password and create todo
OUT=$(curl_json POST /login '{"username":"user_1","password":"newpassword123"}')
ID=$(echo "$OUT" | jq -r '.id')
[[ "$ID" == "1" ]]
OUT=$(curl_json POST /todos '{"title":"Gamma"}')
echo "$OUT" | jq -e '.title=="Gamma" and .completed==false' >/dev/null

# 16. Access control: user2 cannot see user1's todo
OUT=$(curl_json POST /register '{"username":"user_2","password":"password123"}')
OUT=$(curl_json POST /login '{"username":"user_2","password":"password123"}')
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X GET -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/todos/3")
[[ "$CODE" == "404" ]]

# 17. Validation: empty title
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X POST -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data '{"title":""}' "$BASE/todos")
[[ "$CODE" == "400" ]]

# 18. Invalid login should 401
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{"username":"nope","password":"bad"}' "$BASE/login")
[[ "$CODE" == "401" ]]

# 19. Unauthorized should 401 with JSON
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X GET -H 'Content-Type: application/json' "$BASE/todos")
[[ "$CODE" == "401" ]]

# 20. PUT title empty 400
OUT=$(curl_json POST /login '{"username":"user_1","password":"newpassword123"}')
CODE=$(curl -s -o /tmp/out.txt -w '%{http_code}' -X PUT -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data '{"title":""}' "$BASE/todos/3")
[[ "$CODE" == "400" ]]

echo "All tests passed."