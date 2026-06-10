#!/bin/sh
set -eu
PORT=8000

# Parse --port PORT
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      shift
      if [ "$#" -eq 0 ]; then
        echo "Missing PORT after --port" >&2
        exit 1
      fi
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
