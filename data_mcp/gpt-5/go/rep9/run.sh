#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1:-} == "--port" ]]; then
  PORT="$2"
fi

go build -o server .
./server --port "$PORT"
