#!/bin/sh
set -e
PORT=8000
# Parse --port argument
while [ "$1" != "" ]; do
  case $1 in
    --port)
      shift
      PORT=$1
      ;;
    *)
      ;;
  esac
  shift
done

# Ensure Flask is available
if ! python3 -c 'import flask' >/dev/null 2>&1; then
  pip3 install --no-cache-dir flask >/dev/null 2>&1
fi

exec python3 server.py --port "$PORT"