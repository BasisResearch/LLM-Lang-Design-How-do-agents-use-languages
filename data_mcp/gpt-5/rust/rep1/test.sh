#!/usr/bin/env bash
set -euo pipefail
PORT=3100
./run.sh --port "$PORT" &
PID=$!
cleanup(){ kill $PID || true; }
trap cleanup EXIT
sleep 1
base=http://127.0.0.1:$PORT
hdr=(-H 'Content-Type: application/json' -s -D -)

code_from() { printf "%s" "$1" | tr -d '\r' | head -n1 | awk '{print $2}'; }
body_from() { awk 'BEGIN{RS="\r\n\r\n"} NR==2{print $0}'; }
get_cookie() { awk -v IGNORECASE=1 '/^Set-Cookie: /{print $2}' | tr -d '\r' | head -n1; }

# Register
resp=$(curl -s -D - -X POST "$base/register" "${hdr[@]}" --data '{"username":"alice_1","password":"password123"}')
code=$(code_from "$resp"); body=$(printf "%s" "$resp" | body_from)
[ "$code" = "201" ] || { echo "Register failed: $resp"; exit 1; }

# Login
resp=$(curl -s -D - -X POST "$base/login" "${hdr[@]}" --data '{"username":"alice_1","password":"password123"}')
code=$(code_from "$resp"); body=$(printf "%s" "$resp" | body_from)
[ "$code" = "200" ] || { echo "Login failed: $resp"; exit 1; }
cookie=$(printf "%s" "$resp" | get_cookie)
[ -n "$cookie" ] || { echo "No cookie in login response"; exit 1; }

curl_j() { curl -s -D - -H "Cookie: $cookie" -H 'Content-Type: application/json' "$@"; }

# /me
resp=$(curl_j "$base/me"); code=$(code_from "$resp")
[ "$code" = "200" ] || { echo "/me failed: $resp"; exit 1; }

# Create todo
resp=$(curl_j -X POST "$base/todos" --data '{"title":"Task 1","description":"First"}')
code=$(code_from "$resp"); body=$(printf "%s" "$resp" | body_from)
[ "$code" = "201" ] || { echo "Create todo failed: $resp"; exit 1; }
id=$(printf "%s" "$body" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
[ -n "$id" ] || { echo "Failed to parse todo id: $body"; exit 1; }

# List todos
resp=$(curl_j "$base/todos"); code=$(code_from "$resp")
[ "$code" = "200" ] || { echo "List todos failed: $resp"; exit 1; }

# Get todo
resp=$(curl_j "$base/todos/$id"); code=$(code_from "$resp")
[ "$code" = "200" ] || { echo "Get todo failed: $resp"; exit 1; }

# Update todo
resp=$(curl_j -X PUT "$base/todos/$id" --data '{"completed":true,"title":"Task 1 updated"}')
code=$(code_from "$resp")
[ "$code" = "200" ] || { echo "Update todo failed: $resp"; exit 1; }

# Change password
resp=$(curl_j -X PUT "$base/password" --data '{"old_password":"password123","new_password":"newpass123"}')
code=$(code_from "$resp")
[ "$code" = "200" ] || { echo "Change password failed: $resp"; exit 1; }

# Login with old password should fail
resp=$(curl -s -D - -X POST "$base/login" "${hdr[@]}" --data '{"username":"alice_1","password":"password123"}')
code=$(code_from "$resp")
[ "$code" = "401" ] || { echo "Old password login should fail: $resp"; exit 1; }

# Login with new password should succeed
resp2=$(curl -s -D - -X POST "$base/login" "${hdr[@]}" --data '{"username":"alice_1","password":"newpass123"}')
code2=$(code_from "$resp2")
[ "$code2" = "200" ] || { echo "New password login failed: $resp2"; exit 1; }
cookie2=$(printf "%s" "$resp2" | get_cookie)
[ -n "$cookie2" ] || { echo "No cookie in second login response"; exit 1; }

# Logout with second session
resp=$(curl -s -D - -H "Cookie: $cookie2" -H 'Content-Type: application/json' -X POST "$base/logout")
code=$(code_from "$resp")
[ "$code" = "200" ] || { echo "Logout2 failed: $resp"; exit 1; }

# Delete todo
resp=$(curl_j -X DELETE "$base/todos/$id"); code=$(code_from "$resp")
[ "$code" = "204" ] || { echo "Delete todo failed: $resp"; exit 1; }

# Logout
resp=$(curl_j -X POST "$base/logout"); code=$(code_from "$resp")
[ "$code" = "200" ] || { echo "Logout failed: $resp"; exit 1; }

# Subsequent auth should fail
resp=$(curl -s -D - -H "Cookie: $cookie" "$base/me"); code=$(code_from "$resp")
[ "$code" = "401" ] || { echo "Expected 401 after logout: $resp"; exit 1; }

echo "All tests passed"