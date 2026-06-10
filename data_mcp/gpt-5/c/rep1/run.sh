#!/bin/bash
set -euo pipefail
PORT=8080
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done

# Install dependencies if not present
if ! command -v gcc >/dev/null 2>&1; then
  echo "Please ensure gcc is installed" >&2
  exit 1
fi

if ! pkg-config --exists libmicrohttpd; then
  echo "Installing libmicrohttpd-dev..." >&2
  sudo apt-get update && sudo apt-get install -y libmicrohttpd-dev
fi
if ! pkg-config --exists jansson; then
  echo "Installing libjansson-dev..." >&2
  sudo apt-get update && sudo apt-get install -y libjansson-dev
fi
if ! pkg-config --exists uuid; then
  echo "Installing uuid-dev..." >&2
  sudo apt-get update && sudo apt-get install -y uuid-dev
fi

CFLAGS="-O2 -Wall -Wextra -pedantic"
LDFLAGS="$(pkg-config --libs --cflags libmicrohttpd jansson uuid)"

echo "Compiling..."
gcc $CFLAGS server.c -o server $LDFLAGS

echo "Starting server on port $PORT"
./server --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
wait $SERVER_PID
