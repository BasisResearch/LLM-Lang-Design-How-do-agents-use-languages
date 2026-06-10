#!/bin/bash
set -euo pipefail
PORT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done
if [[ "$PORT" == "0" || -z "${PORT}" ]]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi

# Compile
if [[ ! -f server ]]; then
  :
fi

gcc -O2 -Wall -Wextra -o server server.c
exec ./server --port "$PORT"
