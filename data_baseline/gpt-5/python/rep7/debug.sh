#!/bin/sh
set -euo pipefail
PORT=19111
./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
sleep 0.4
BASE="http://127.0.0.1:$PORT"
HDR=$(mktemp)

curl -sS -X POST -H 'Content-Type: application/json' -d '{"username":"u","password":"password123"}' "$BASE/register" || true
curl -sS -D "$HDR" -X POST -H 'Content-Type: application/json' -d '{"username":"u","password":"password123"}' "$BASE/login" -o /tmp/body.txt || true

echo '--- HEADERS ---'
cat "$HDR"
echo '--- BODY ---'
cat /tmp/body.txt
