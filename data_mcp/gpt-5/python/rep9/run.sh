#!/bin/sh
set -e
PORT=8000
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

# Run with system python, no external deps required
exec python3 server.py --port "$PORT"