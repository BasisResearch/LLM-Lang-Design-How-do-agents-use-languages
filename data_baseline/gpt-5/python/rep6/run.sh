#!/bin/sh
PORT=8000
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *)
      echo "Unknown argument: $1" 1>&2; exit 1;;
  esac
done
exec python3 server.py --port "$PORT"
