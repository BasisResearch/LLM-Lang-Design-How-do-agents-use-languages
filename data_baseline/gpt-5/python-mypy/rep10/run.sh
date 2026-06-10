#!/bin/sh
set -eu
PORT=0
if [ "$#" -ge 2 ] && [ "$1" = "--port" ]; then
  PORT="$2"
else
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
PY=python3
if [ -x "venv/bin/python" ]; then
  PY="venv/bin/python"
fi
exec "$PY" server.py --port "$PORT"
