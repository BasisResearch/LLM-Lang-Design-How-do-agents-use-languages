#!/bin/bash
set -euo pipefail
PORT=8000
# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

# ensure deps
if ! command -v gcc >/dev/null 2>&1; then
  echo "gcc not found. Installing build-essential..." >&2
  sudo apt-get update -y && sudo apt-get install -y build-essential
fi
if ! pkg-config --exists jansson; then
  echo "jansson not found. Installing libjansson-dev..." >&2
  sudo apt-get update -y && sudo apt-get install -y libjansson-dev pkg-config
fi
if ! pkg-config --exists openssl; then
  echo "openssl dev not found. Installing libssl-dev..." >&2
  sudo apt-get update -y && sudo apt-get install -y libssl-dev pkg-config
fi

CFLAGS="-O2 -Wall -Wextra -pedantic"
LIBS=$(pkg-config --libs --cflags jansson openssl)

echo "Compiling..."
gcc $CFLAGS main.c -o server $LIBS

echo "Starting server on port ${PORT}..."
exec ./server --port "$PORT"
