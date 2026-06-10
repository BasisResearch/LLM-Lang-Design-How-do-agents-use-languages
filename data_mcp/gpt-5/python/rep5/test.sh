#!/bin/sh
set -eu

PORT=8123
SERVER_LOG=server_test.log
COOKIE_JAR=$(mktemp)
TMP_DIR=$(mktemp -d)
RES_HEADERS="$TMP_DIR/headers.txt"
RES_BODY="$TMP_DIR/body.txt"
RESP_ALL="$TMP_DIR/resp.txt"

cleanup() {
  rm -f "$COOKIE_JAR"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap stop_server EXIT

# Wait for server to be ready
for i in $(seq 1 50); do
  if curl -sS "http://127.0.0.1:$PORT/me" -o /dev/null -w '' 2>/dev/null; then
    break
  fi
  sleep 0.1
done

request() {
  METHOD="$1"; shift
  URL="http://127.0.0.1:$PORT$1"; shift
  DATA="${1-}"
  : >"$RES_HEADERS"
  : >"$RES_BODY"
  : >"$RESP_ALL"
  if [ -n "$DATA" ]; then
    curl -sS -i -X "$METHOD" "$URL" \
      -H 'Content-Type: application/json' \
      -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
      --data "$DATA" \
      > "$RESP_ALL"
  else
    curl -sS -i -X "$METHOD" "$URL" \
      -H 'Content-Type: application/json' \
      -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
      > "$RESP_ALL"
  fi
  # Split headers and body at first empty line
  awk 'BEGIN{h=1} {if(h){print > hfile} else {print > bfile}} /^\r?$/ {if(h){h=0}}' \
    hfile="$RES_HEADERS" bfile="$RES_BODY" "$RESP_ALL" 2>/dev/null || true
}

status_code() {
  head -n1 "$RES_HEADERS" | awk '{print $2}'
}

assert_status() {
  expected="$1"
  got=$(status_code)
  if [ "$got" != "$expected" ]; then
    echo "Expected status $expected, got $got" >&2
    echo "Headers:" >&2
    cat "$RES_HEADERS" >&2 || true
    echo "Body:" >&2
    cat "$RES_BODY" >&2 || true
    exit 1
  fi
}

assert_content_type_json_if_body() {
  if [ -s "$RES_BODY" ]; then
    if ! grep -i '^Content-Type: application/json' "$RES_HEADERS" >/dev/null; then
      echo "Missing or wrong Content-Type for JSON response" >&2
      cat "$RES_HEADERS" >&2
      exit 1
    fi
  fi
}

assert_header_contains() {
  header="$1"; substr="$2"
  if ! grep -i "^$header:" "$RES_HEADERS" | grep -F "$substr" >/dev/null; then
    echo "Header $header does not contain $substr" >&2
    cat "$RES_HEADERS" >&2
    exit 1
  fi
}

json_get() {
  python3 - "$@" << 'PY'
import sys, json
import argparse
p=argparse.ArgumentParser(add_help=False)
p.add_argument('--key', required=True)
args, rest = p.parse_known_args()
# The last arg is the file path
path = rest[-1]
with open(path,'rb') as f:
    data=f.read()
obj=json.loads(data.decode())
cur=obj
for part in args.key.split('.'):
    if isinstance(cur, list):
        if part == 'len':
            print(len(cur))
            sys.exit(0)
        idx=int(part)
        cur=cur[idx]
    else:
        cur=cur.get(part)
print(cur if not isinstance(cur, bool) else ('true' if cur else 'false'))
PY
}

assert_json_equals() {
  key="$1"; expected="$2"
  val=$(json_get --key "$key" "$RES_BODY")
  if [ "$val" != "$expected" ]; then
    echo "JSON $key expected '$expected', got '$val'" >&2
    cat "$RES_BODY" >&2
    exit 1
  fi
}

# Begin tests

# 1) Register user
request POST /register '{"username":"alice","password":"password123"}'
assert_status 201
assert_content_type_json_if_body
assert_json_equals id 1
assert_json_equals username alice

# Duplicate username
request POST /register '{"username":"alice","password":"anotherpass"}'
assert_status 409
assert_content_type_json_if_body

# 2) Login
request POST /login '{"username":"alice","password":"password123"}'
assert_status 200
assert_content_type_json_if_body
assert_header_contains Set-Cookie 'session_id='

# 3) /me
request GET /me
assert_status 200
assert_content_type_json_if_body
assert_json_equals username alice

# 4) Change password invalid old
request PUT /password '{"old_password":"wrong","new_password":"newpassword"}'
assert_status 401

# 5) Change password too short
request PUT /password '{"old_password":"password123","new_password":"short"}'
assert_status 400

# 6) Change password success
request PUT /password '{"old_password":"password123","new_password":"newpassword"}'
assert_status 200

# 7) List todos (empty)
request GET /todos
assert_status 200
assert_json_equals len 0

# 8) Create todo
request POST /todos '{"title":"Buy milk","description":"2% organic"}'
assert_status 201
assert_json_equals title 'Buy milk'
assert_json_equals completed false

# 9) List todos (one)
request GET /todos
assert_status 200
assert_json_equals len 1

# 10) Get todo by id
request GET /todos/1
assert_status 200
assert_json_equals id 1

# 11) Update todo title and completed
request PUT /todos/1 '{"title":"Buy bread","completed":true}'
assert_status 200
assert_json_equals title 'Buy bread'
assert_json_equals completed true

# 12) Create second user and try to access Alice's todo
request POST /register '{"username":"bob","password":"password123"}'
assert_status 201
request POST /login '{"username":"bob","password":"password123"}'
assert_status 200
request GET /todos/1
assert_status 404

# 13) Switch back to Alice and delete todo
request POST /login '{"username":"alice","password":"newpassword"}'
assert_status 200
request DELETE /todos/1
assert_status 204
# No body expected
if [ -s "$RES_BODY" ]; then echo "Expected empty body on DELETE" >&2; exit 1; fi

# 14) Get deleted todo
request GET /todos/1
assert_status 404

# 15) Logout and access /me
request POST /logout
assert_status 200
request GET /me
assert_status 401

# 16) Validation: create todo with empty title
request POST /login '{"username":"alice","password":"newpassword"}'
assert_status 200
request POST /todos '{"title":""}'
assert_status 400

echo "All tests passed"