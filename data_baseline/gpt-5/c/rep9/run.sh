#!/usr/bin/env bash
set -euo pipefail

PORT=0
if [[ $# -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
else
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi

# Install dependencies if not present
if ! pkg-config --exists libmicrohttpd 2>/dev/null || ! pkg-config --exists jansson 2>/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y gcc make pkg-config libmicrohttpd-dev libjansson-dev uuid-dev
fi

# Build
CFLAGS="-O2 -Wall -Wextra"
LDFLAGS="-lmicrohttpd -ljansson -luuid"
if [[ ! -f server ]] || [[ server.c -nt server ]]; then
  gcc $CFLAGS -o server server.c $LDFLAGS
fi

exec ./server --port "$PORT"
