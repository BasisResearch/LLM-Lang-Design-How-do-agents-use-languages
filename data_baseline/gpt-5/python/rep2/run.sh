#!/bin/sh
set -e
PORT=8000
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
exec python3 server.py --port "$PORT"