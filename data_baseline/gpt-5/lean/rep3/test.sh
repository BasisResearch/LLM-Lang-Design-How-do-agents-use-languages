#!/usr/bin/env bash
set -euo pipefail
PORT=19234
BASE="http://127.0.0.1:$PORT"

cleanup() {
  if [[ -f server.pid ]]; then
    kill "$(cat server.pid)" 2>/dev/null || true
    rm -f server.pid
  fi
}
trap cleanup EXIT

chmod +x run.sh
./run.sh --port "$PORT" >/dev/null 2>&1 & echo $! > server.pid

# wait for server
tries=0
until curl -sS -o /dev/null "$BASE/healthz" || curl -sS -o /dev/null "$BASE/register"; do
  tries=$((tries+1))
  if (( tries > 180 )); then
    echo "Server did not start in time"
    exit 1
  fi
  sleep 1
done

curl_json() {
  local method=$1
  local path=$2
  local data=${3:-}
  local cookie=${4:-}
  local tmpdir=$(mktemp -d)
  local hdr="$tmpdir/h"
  local body="$tmpdir/b"
  if [[ -n "$data" ]]; then
    if [[ -n "$cookie" ]]; then
      curl -sS -D "$hdr" -o "$body" -X "$method" "$BASE$path" -H 'Content-Type: application/json' -H "Cookie: $cookie" --data "$data"
    else
      curl -sS -D "$hdr" -o "$body" -X "$method" "$BASE$path" -H 'Content-Type: application/json' --data "$data"
    fi
  else
    if [[ -n "$cookie" ]]; then
      curl -sS -D "$hdr" -o "$body" -X "$method" "$BASE$path" -H "Cookie: $cookie"
    else
      curl -sS -D "$hdr" -o "$body" -X "$method" "$BASE$path"
    fi
  fi
  local status=$(head -n1 "$hdr" | awk '{print $2}')
  echo "$status" > "$tmpdir/status"
  echo "$hdr" "$body" "$tmpdir/status"
}

get_status() { cat "$1"; }
get_header() { local file=$1; local name=$2; awk -v IGNORECASE=1 -v n="$name:" '$0~n{print substr($0,index($0,":")+2)}' "$file" | tr -d '\r'; }

# 1) Register user
read HDR BODY STAT < <(curl_json POST /register '{"username":"alice","password":"password123"}')
[[ $(get_status "$STAT") == 201 ]] || { echo "Register failed"; cat "$BODY"; exit 1; }
[[ $(get_header "$HDR" Content-Type) == application/json ]] || { echo "Missing Content-Type"; exit 1; }

# 2) Duplicate username
read HDR BODY STAT < <(curl_json POST /register '{"username":"alice","password":"password123"}')
[[ $(get_status "$STAT") == 409 ]] || { echo "Duplicate username check failed"; cat "$BODY"; exit 1; }

# 3) Login wrong
read HDR BODY STAT < <(curl_json POST /login '{"username":"alice","password":"wrongpass"}')
[[ $(get_status "$STAT") == 401 ]] || { echo "Login wrong should 401"; exit 1; }

# 4) Login correct
read HDR BODY STAT < <(curl_json POST /login '{"username":"alice","password":"password123"}')
[[ $(get_status "$STAT") == 200 ]] || { echo "Login correct failed"; cat "$BODY"; exit 1; }
COOKIE=$(awk '/^Set-Cookie:/{print $0}' "$HDR" | sed -n 's/^Set-Cookie: \(session_id=[^;]*\).*/\1/p' | tr -d '\r')
[[ -n "$COOKIE" ]] || { echo "Missing Set-Cookie"; exit 1; }

# 5) /me
read HDR BODY STAT < <(curl_json GET /me '' "$COOKIE")
[[ $(get_status "$STAT") == 200 ]] || { echo "/me failed"; exit 1; }

# 6) PUT /password wrong old
read HDR BODY STAT < <(curl_json PUT /password '{"old_password":"bad","new_password":"newpassword"}' "$COOKIE")
[[ $(get_status "$STAT") == 401 ]] || { echo "password wrong old should 401"; exit 1; }

# 7) PUT /password short new
read HDR BODY STAT < <(curl_json PUT /password '{"old_password":"password123","new_password":"short"}' "$COOKIE")
[[ $(get_status "$STAT") == 400 ]] || { echo "password short should 400"; exit 1; }

# 8) PUT /password ok
read HDR BODY STAT < <(curl_json PUT /password '{"old_password":"password123","new_password":"newpassword"}' "$COOKIE")
[[ $(get_status "$STAT") == 200 ]] || { echo "password change failed"; exit 1; }

# 9) POST /logout
read HDR BODY STAT < <(curl_json POST /logout '' "$COOKIE")
[[ $(get_status "$STAT") == 200 ]] || { echo "logout failed"; exit 1; }

# 10) /me should be 401 now
read HDR BODY STAT < <(curl_json GET /me '' "$COOKIE")
[[ $(get_status "$STAT") == 401 ]] || { echo "token should be invalid after logout"; exit 1; }

# 11) Login again with new pass
read HDR BODY STAT < <(curl_json POST /login '{"username":"alice","password":"newpassword"}')
[[ $(get_status "$STAT") == 200 ]] || { echo "re-login failed"; exit 1; }
COOKIE=$(awk '/^Set-Cookie:/{print $0}' "$HDR" | sed -n 's/^Set-Cookie: \(session_id=[^;]*\).*/\1/p' | tr -d '\r')

# 12) GET /todos (empty)
read HDR BODY STAT < <(curl_json GET /todos '' "$COOKIE")
[[ $(get_status "$STAT") == 200 ]] || { echo "GET /todos failed"; exit 1; }
[[ $(cat "$BODY") == "[]" ]] || true # may include spaces, but empty ok

# 13) POST /todos missing title
read HDR BODY STAT < <(curl_json POST /todos '{"description":"d"}' "$COOKIE")
[[ $(get_status "$STAT") == 400 ]] || { echo "POST /todos missing title should 400"; exit 1; }

# 14) POST /todos ok
read HDR BODY STAT < <(curl_json POST /todos '{"title":"t1","description":"d1"}' "$COOKIE")
[[ $(get_status "$STAT") == 201 ]] || { echo "POST /todos failed"; cat "$BODY"; exit 1; }

# 15) GET /todos/1
read HDR BODY STAT < <(curl_json GET /todos/1 '' "$COOKIE")
[[ $(get_status "$STAT") == 200 ]] || { echo "GET /todos/1 failed"; exit 1; }

# 16) PUT /todos/1 empty title -> 400
read HDR BODY STAT < <(curl_json PUT /todos/1 '{"title":""}' "$COOKIE")
[[ $(get_status "$STAT") == 400 ]] || { echo "PUT /todos/1 empty title should 400"; exit 1; }

# 17) PUT /todos/1 update
read HDR BODY STAT < <(curl_json PUT /todos/1 '{"completed":true,"title":"t1-upd","description":"d1-upd"}' "$COOKIE")
[[ $(get_status "$STAT") == 200 ]] || { echo "PUT /todos/1 failed"; exit 1; }

# 18) DELETE /todos/1
# Expect 204 and no body
TMP=$(mktemp -d)
HDRF="$TMP/h"; BODYF="$TMP/b"
curl -sS -D "$HDRF" -o "$BODYF" -X DELETE "$BASE/todos/1" -H "Cookie: $COOKIE"
STATUS=$(head -n1 "$HDRF" | awk '{print $2}')
[[ "$STATUS" == 204 ]] || { echo "DELETE /todos/1 failed"; exit 1; }
[[ ! -s "$BODYF" ]] || { echo "DELETE should return no body"; exit 1; }

# 19) GET /todos/1 -> 404
read HDR BODY STAT < <(curl_json GET /todos/1 '' "$COOKIE")
[[ $(get_status "$STAT") == 404 ]] || { echo "GET /todos/1 should 404 after delete"; exit 1; }

echo "All tests passed"