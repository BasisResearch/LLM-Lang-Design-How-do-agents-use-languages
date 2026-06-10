#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" ]]; then
  PORT=${2-8080}
fi
# Install dependencies if missing
if ! command -v gcc >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y build-essential
fi
need_install=false
pkg-config --exists libmicrohttpd || need_install=true
pkg-config --exists jansson || need_install=true
if $need_install; then
  sudo apt-get update -y
  sudo apt-get install -y libmicrohttpd-dev libjansson-dev
fi

CFLAGS="-O2 -g -Wall -Wextra"
LIBS="$(pkg-config --libs --cflags libmicrohttpd jansson)"

echo "Compiling..."
rm -f server
gcc $CFLAGS main.c -o server $LIBS

echo "Starting server on port $PORT"
exec ./server --port "$PORT"
