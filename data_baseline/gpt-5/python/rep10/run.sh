#!/bin/sh
# Start the Todo server
PORT=8000
# Parse --port argument
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      shift
      PORT="$1"
      ;;
  esac
  shift
done
exec python3 server.py --port "$PORT"
