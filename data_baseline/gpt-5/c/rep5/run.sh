#!/bin/bash
set -euo pipefail
PORT=8080
if [[ "${1-}" == "--port" ]]; then
  PORT="$2"
fi
# Install dependencies if missing
if ! command -v gcc >/dev/null 2>&1; then
  echo "gcc is required" >&2
  exit 1
fi
if ! pkg-config --exists jansson 2>/dev/null; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y libjansson-dev
  fi
fi
CFLAGS="-O2 -Wall -Wextra -std=c11"
LDFLAGS="$(pkg-config --libs jansson)"
INCLUDES="$(pkg-config --cflags jansson)"

echo "Compiling..."
gcc $CFLAGS $INCLUDES server.c -o server $LDFLAGS

echo "Starting server on port $PORT"
exec ./server --port "$PORT"
