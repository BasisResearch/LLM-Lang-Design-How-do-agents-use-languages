#!/bin/sh
set -eu
PORT=8080
if [ "$#" -ge 2 ] && [ "$1" = "--port" ]; then
  PORT=$2
fi
exec python3 server.py --port "$PORT"
