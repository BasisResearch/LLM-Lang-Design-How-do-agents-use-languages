#!/bin/bash
set -euo pipefail

PORT=8080

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      shift
      if [[ $# -eq 0 ]]; then
        echo "--port requires a value" >&2
        exit 1
      fi
      PORT="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Ensure dependencies
if ! command -v gcc >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y build-essential
fi

if ! pkg-config --exists libmicrohttpd 2>/dev/null; then
  sudo apt-get update
  sudo apt-get install -y libmicrohttpd-dev
fi

if ! pkg-config --exists jansson 2>/dev/null; then
  sudo apt-get update
  sudo apt-get install -y libjansson-dev
fi

CFLAGS="-O2 -Wall -Wextra -pedantic -std=c11 $(pkg-config --cflags libmicrohttpd jansson)"
LDFLAGS="$(pkg-config --libs libmicrohttpd jansson) -lpthread"

gcc $CFLAGS -o server main.c $LDFLAGS

# Run the server
./server --port "$PORT"
