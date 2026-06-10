#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "$#" -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
# Install dependencies if not present (for local runs)
if ! command -v gcc >/dev/null 2>&1; then
  echo "gcc not found" >&2
  exit 1
fi
if ! pkg-config --exists libmicrohttpd; then
  echo "Installing libmicrohttpd-dev..." >&2
  sudo apt-get update && sudo apt-get install -y libmicrohttpd-dev
fi
if ! pkg-config --exists libuuid; then
  echo "Installing uuid-dev..." >&2
  sudo apt-get update && sudo apt-get install -y uuid-dev
fi
if ! pkg-config --exists libcjson; then
  echo "Installing libcjson-dev..." >&2
  sudo apt-get update && sudo apt-get install -y libcjson-dev
fi
CFLAGS="-O2 -Wall -Wextra -std=c11"
LIBS="$(pkg-config --libs --cflags libmicrohttpd libcjson libuuid)"
mkdir -p build
cc $CFLAGS server.c -o build/server $LIBS
exec build/server --port "$PORT"
