#!/usr/bin/env bash
set -euo pipefail
PORT=18081
./run.sh --port $PORT >/tmp/server2.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
sleep 3
base=http://127.0.0.1:$PORT

echo REG
echo $(curl -sS -X POST $base/register -H 'Content-Type: application/json' -d '{"username":"u","password":"password123"}')

COOKIE=$(mktemp)
echo LOGIN
curl -sS -X POST $base/login -H 'Content-Type: application/json' -d '{"username":"u","password":"password123"}' -c $COOKIE | tee /dev/stderr

echo CREATE1
curl -sS -X POST $base/todos -H 'Content-Type: application/json' -d '{"title":"A","description":"D"}' -b $COOKIE | tee /dev/stderr

echo CREATE2
curl -sS -X POST $base/todos -H 'Content-Type: application/json' -d '{"title":"B"}' -b $COOKIE | tee /dev/stderr

echo LIST
curl -sS $base/todos -b $COOKIE | tee /dev/stderr

echo GET1
code=$(curl -sS -o /dev/stderr -w '%{http_code}' $base/todos/1 -b $COOKIE)
echo CODE=$code
