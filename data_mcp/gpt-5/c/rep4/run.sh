#!/bin/bash
set -euo pipefail
PORT=8080
if [[ "${1-}" == "--port" && -n "${2-}" ]]; then
  PORT="$2"
fi

# Install dependencies if missing
if ! command -v gcc >/dev/null 2>&1; then
  echo "gcc not found. Installing build-essential..."
  sudo apt-get update && sudo apt-get install -y build-essential
fi

if ! pkg-config --exists libmicrohttpd; then
  echo "Installing libmicrohttpd..."
  sudo apt-get update && sudo apt-get install -y libmicrohttpd-dev
fi

if ! pkg-config --exists jansson; then
  echo "Installing jansson..."
  sudo apt-get update && sudo apt-get install -y libjansson-dev
fi

CFLAGS="-O2 -Wall -Wextra -Werror"
LIBS="$(pkg-config --cflags --libs libmicrohttpd jansson)"

echo "Compiling..."
rm -f server
gcc $CFLAGS main.c -o server $LIBS

echo "Starting server on port $PORT"
exec ./server --port "$PORT"