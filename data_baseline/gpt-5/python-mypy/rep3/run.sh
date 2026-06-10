#!/bin/sh
set -eu
PORT=0
# parse --port PORT
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      shift
      PORT="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done
if [ "$PORT" = "0" ] || [ -z "$PORT" ]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
exec python3 server.py --port "$PORT"
