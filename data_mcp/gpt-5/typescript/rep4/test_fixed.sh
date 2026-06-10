#!/usr/bin/env bash
set -euo pipefail
PORT=33333
BASE="http://127.0.0.1:${PORT}"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

npm run build --silent
node dist/index.js --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

# Wait health
for i in {1..100}; do
  if curl -sfS --max-time 2 "${BASE}/health" >/dev/null; then break; fi
  sleep 0.05
done

jcurl() { curl -sS -X "$1" "${BASE}$2" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" ${3:-}; }

RESP=$(jcurl POST /register -d '{"username":"user_one","password":"password123"}')
ID=$(echo "$RESP" | jq -r .id)
[[ "$ID" == "1" ]] || { echo "Register: $RESP"; exit 1; }

RESP=$(jcurl POST /login -d '{"username":"user_one","password":"password123"}')
[[ $(echo "$RESP" | jq -r .username) == user_one ]] || { echo "Login: $RESP"; exit 1; }

RESP=$(jcurl POST /todos -d '{"title":"Task 1","description":"Desc"}')
ID1=$(echo "$RESP" | jq -r .id)
RESP=$(jcurl GET /todos/$ID1)
[[ $(echo "$RESP" | jq -r .title) == "Task 1" ]] || { echo "Get: $RESP"; exit 1; }

echo OK
