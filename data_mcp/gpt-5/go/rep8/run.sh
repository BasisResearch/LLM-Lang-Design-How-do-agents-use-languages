#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ $# -ge 2 && $1 == "--port" ]]; then
  PORT=$2
fi
# build
mkdir -p bin
GO111MODULE=on go build -o bin/server ./cmd/server
# run
exec ./bin/server --port "$PORT"
