#!/usr/bin/env bash
set -euo pipefail
PORT=8000
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
# Ensure dependencies
if ! dpkg -s libjansson-dev >/dev/null 2>&1; then
  echo "Installing dependencies..." >&2
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y build-essential libjansson-dev >/dev/null 2>&1
fi

echo "Compiling..." >&2
cc -O2 -Wall -Wextra -pedantic -std=c11 server.c -o server -ljansson

echo "Starting server on port $PORT" >&2
exec ./server --port "$PORT"
