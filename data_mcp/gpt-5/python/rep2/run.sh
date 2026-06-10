#!/bin/sh
set -eu
PORT=8000
# Parse --port PORT
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done
# Best effort to ensure Flask is available
pip3 install --quiet flask >/dev/null 2>&1 || true
exec python3 server.py --port "$PORT"