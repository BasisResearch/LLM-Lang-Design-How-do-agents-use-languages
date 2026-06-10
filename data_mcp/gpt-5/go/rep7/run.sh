#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1:-} == "--port" ]]; then
  PORT=${2:-8080}
fi
mkdir -p build
GOFLAGS="${GOFLAGS:-}"
echo "Building server..."
go build -o build/server .
echo "Starting server on 0.0.0.0:${PORT}"
exec ./build/server --port "${PORT}"
