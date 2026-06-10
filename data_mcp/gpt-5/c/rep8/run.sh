#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" && -n ${2-} ]]; then
  PORT="$2"
fi
# Install dependencies if missing
if ! pkg-config --exists libmicrohttpd || ! pkg-config --exists jansson; then
  echo "Installing dependencies..." >&2
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get install -y build-essential pkg-config libmicrohttpd-dev libjansson-dev
fi

echo "Compiling..." >&2
cc -O2 -Wall -Wextra -o server main.c -lmicrohttpd -ljansson -lpthread

echo "Starting server on 0.0.0.0:${PORT}" >&2
exec ./server --port "$PORT"