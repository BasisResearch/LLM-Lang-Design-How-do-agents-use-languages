#!/usr/bin/env bash
set -euo pipefail
PORT=0
if [[ $# -ge 2 && $1 == "--port" ]]; then
  PORT=$2
else
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
# Ensure Flask is installed
if ! python3 -c 'import flask' >/dev/null 2>&1; then
  python3 -m pip install --quiet flask
fi
exec python3 server.py --port "$PORT"