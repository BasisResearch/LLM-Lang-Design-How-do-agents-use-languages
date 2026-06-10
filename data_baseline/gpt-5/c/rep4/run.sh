#!/usr/bin/env bash
set -euo pipefail
PORT=""
if [[ $# -ge 2 && $1 == "--port" ]]; then
  PORT="$2"
elif [[ $1 =~ --port=([0-9]+) ]]; then
  PORT="${BASH_REMATCH[1]}"
else
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi

# Install dependencies if not present
if ! command -v gcc >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y build-essential
fi
if ! pkg-config --exists libmicrohttpd || ! pkg-config --exists jansson || ! ldconfig -p | grep -q libuuid.so; then
  sudo apt-get update -y
  sudo apt-get install -y libmicrohttpd-dev libjansson-dev uuid-dev
fi

# Build
CFLAGS="-O2 -Wall -Wextra -Werror"
LDFLAGS="$(pkg-config --libs --cflags libmicrohttpd jansson) -luuid"

echo "Compiling server.c..."
# shellcheck disable=SC2086
gcc $CFLAGS server.c -o server $LDFLAGS

echo "Starting server on 0.0.0.0:${PORT}"
exec ./server --port "$PORT"
