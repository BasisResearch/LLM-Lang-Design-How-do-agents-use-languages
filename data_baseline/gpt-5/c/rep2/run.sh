#!/usr/bin/env bash
set -euo pipefail
PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    -p)
      PORT="$2"; shift 2;;
    *)
      echo "Usage: $0 --port PORT" >&2; exit 1;;
  esac
done
if [[ -z "${PORT}" ]]; then
  echo "Usage: $0 --port PORT" >&2; exit 1
fi

# Ensure dependencies
if ! command -v gcc >/dev/null 2>&1; then
  apt-get update && apt-get install -y gcc
fi
if ! ldconfig -p | grep -q libmicrohttpd.so; then
  apt-get update && apt-get install -y libmicrohttpd-dev
fi
if ! ldconfig -p | grep -q libjansson.so; then
  apt-get update && apt-get install -y libjansson-dev
fi

# Build
CFLAGS="-O2 -Wall -Wextra"
LDFLAGS="-lmicrohttpd -ljansson -lpthread"

echo "Compiling server..."
rm -f server
gcc $CFLAGS -o server main.c $LDFLAGS

echo "Starting server on 0.0.0.0:${PORT}"
exec ./server --port "${PORT}"
