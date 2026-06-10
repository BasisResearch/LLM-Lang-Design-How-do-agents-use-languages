#!/usr/bin/env bash
set -euo pipefail
PORT=${1:-26080}
( cd todo_server && cargo build --release >/dev/null 2>&1 || cargo build --release )
./todo_server/target/release/todo_server --port $PORT &
PID=$!
trap "kill $PID; wait $PID 2>/dev/null || true" EXIT
sleep 0.5
base=http://127.0.0.1:$PORT

echo '{"username":"user_1","password":"password123"}' > /tmp/reg.json
curl -s -i -H 'Content-Type: application/json' -X POST $base/register --data-binary @/tmp/reg.json | sed -n '1,60p'

echo '{"username":"user_1","password":"password123"}' > /tmp/login.json
curl -s -i -c /tmp/cjar.txt -b /tmp/cjar.txt -H 'Content-Type: application/json' -X POST $base/login --data-binary @/tmp/login.json | sed -n '1,80p'

echo 'GET /me'
curl -s -i -c /tmp/cjar.txt -b /tmp/cjar.txt $base/me | sed -n '1,80p'

echo '{"title":"First","description":"desc"}' > /tmp/t1.json
curl -s -i -c /tmp/cjar.txt -b /tmp/cjar.txt -H 'Content-Type: application/json' -X POST $base/todos --data-binary @/tmp/t1.json | sed -n '1,120p'

kill $PID; wait $PID 2>/dev/null || true
trap - EXIT
