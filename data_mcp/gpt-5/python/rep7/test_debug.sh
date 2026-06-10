#!/usr/bin/env bash
set -euo pipefail
PORT=8126
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
LOG_FILE=$(mktemp)
cleanup(){
  echo "--- Server log (end) ---"; cat "$LOG_FILE" || true; echo "-----------------------";
  if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" >/dev/null 2>&1 || true; wait "$SERVER_PID" >/dev/null 2>&1 || true; fi
  rm -f "$COOKIE_JAR" "$LOG_FILE"
}
trap cleanup EXIT
./run.sh --port "$PORT" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!
for i in {1..50}; do curl -sS -o /dev/null "$BASE/me" && break; sleep 0.1; done
sleep 0.2
# up to login
set -x
curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}'
# login and keep cookie
curl -sS -D - -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' -o /dev/null | tr -d '\r'
# check process
ps -p "$SERVER_PID" -o pid,cmd
# change password
curl -v -sS -b "$COOKIE_JAR" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword456"}'
# check process again
ps -p "$SERVER_PID" -o pid,cmd
