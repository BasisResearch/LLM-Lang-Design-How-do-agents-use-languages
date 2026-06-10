#!/bin/bash
set -euxo pipefail
PORT=$(( ( RANDOM % 20000 ) + 20000 ))
./run.sh --port "$PORT" &
PID=$!
sleep 1
curl -sS --max-time 5 -H 'Content-Type: application/json' -d '{"username":"u1","password":"password123"}' "http://127.0.0.1:$PORT/register" -D - -o /dev/null
kill $PID
wait $PID || true
