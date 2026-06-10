#!/bin/sh
set -eu
PORT=8000
# Parse args --port PORT
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      shift
      PORT="$1"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done
exec python3 server.py --port "$PORT"