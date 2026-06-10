#!/usr/bin/env bash
set -euo pipefail
PORT=""
if [[ "${1-}" == "--port" ]]; then
  PORT="$2"
else
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
exec python3 server.py --port "$PORT"