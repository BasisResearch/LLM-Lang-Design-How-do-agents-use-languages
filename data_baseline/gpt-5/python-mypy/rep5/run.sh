#!/bin/sh
set -e
PORT=0
while [ "$1" != "" ]; do
  case $1 in
    --port)
      shift
      PORT=$1
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done
if [ "$PORT" = "0" ] || [ -z "$PORT" ]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
exec python3 server.py --port "$PORT"
