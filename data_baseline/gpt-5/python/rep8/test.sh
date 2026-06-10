#!/bin/bash
set -euo pipefail
PORT=8090
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)

function curl_json() {
  curl -sS -D /tmp/headers.$$ -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' "$@"
}

echo "1) Register user"
curl_json -X POST "$BASE/register" -d '{"username":"test_user","password":"password123"}' | tee /tmp/out1.json

# Duplicate username should 409
STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"test_user","password":"password123"}' -X POST "$BASE/register")
[[ "$STATUS" == "409" ]] || { echo "Expected 409, got $STATUS"; exit 1; }

echo "2) Login"
curl_json -X POST "$BASE/login" -d '{"username":"test_user","password":"password123"}' | tee /tmp/out2.json

# Get me
echo "3) Me"
curl_json -X GET "$BASE/me" | tee /tmp/me.json

# Change password
echo "4) Change password"
curl_json -X PUT "$BASE/password" -d '{"old_password":"password123","new_password":"newpassword456"}' | tee /tmp/pw.json

# Logout
echo "5) Logout"
curl_json -X POST "$BASE/logout" | tee /tmp/logout.json

# Auth should now fail
STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -H 'Content-Type: application/json' "$BASE/me")
[[ "$STATUS" == "401" ]] || { echo "Expected 401 after logout, got $STATUS"; exit 1; }

# Login with new password
echo "6) Login with new password"
curl_json -X POST "$BASE/login" -d '{"username":"test_user","password":"newpassword456"}' | tee /tmp/out3.json

# Create todos
echo "7) Create todos"
T1=$(curl_json -X POST "$BASE/todos" -d '{"title":"Task 1","description":"Desc 1"}')
T2=$(curl_json -X POST "$BASE/todos" -d '{"title":"Task 2"}')

echo "$T1" | tee /tmp/t1.json

echo "8) List todos"
curl_json -X GET "$BASE/todos" | tee /tmp/list.json

# Get id from T1
ID1=$(python3 - <<'PY'
import json,sys
print(json.load(open('/tmp/t1.json'))['id'])
PY
)

echo "9) Get todo $ID1"
curl_json -X GET "$BASE/todos/$ID1" | tee /tmp/get1.json

# Update todo
echo "10) Update todo $ID1"
curl_json -X PUT "$BASE/todos/$ID1" -d '{"completed": true, "description": "Updated"}' | tee /tmp/update1.json

# Delete todo
echo "11) Delete todo $ID1"
STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' -X DELETE "$BASE/todos/$ID1")
[[ "$STATUS" == "204" ]] || { echo "Expected 204 on delete, got $STATUS"; exit 1; }

# Get should now 404
STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -H 'Content-Type: application/json' "$BASE/todos/$ID1")
[[ "$STATUS" == "404" ]] || { echo "Expected 404 after delete, got $STATUS"; exit 1; }

echo "All tests passed."
