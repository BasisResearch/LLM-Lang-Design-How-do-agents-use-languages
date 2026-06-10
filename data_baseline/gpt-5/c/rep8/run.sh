#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1-}" == "--port" && -n "${2-}" ]]; then
  PORT="$2"
fi
# Install dependencies if missing
if ! command -v gcc >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y gcc make pkg-config
fi
if ! pkg-config --exists libmicrohttpd 2>/dev/null; then
  sudo apt-get update -y
  sudo apt-get install -y libmicrohttpd-dev
fi
if ! pkg-config --exists libcjson 2>/dev/null; then
  sudo apt-get update -y
  sudo apt-get install -y libcjson-dev
fi
CFLAGS="-O2 -Wall -Wextra"
LDFLAGS="$(pkg-config --libs libmicrohttpd libcjson) -lpthread"
INCFLAGS="$(pkg-config --cflags libmicrohttpd libcjson)"

echo "Compiling server..."
set -x
gcc ${CFLAGS} ${INCFLAGS} -o server main.c ${LDFLAGS}
set +x

echo "Starting server on 0.0.0.0:${PORT}"
# Replace shell with server process so PID is propagated
exec ./server --port "${PORT}"