#!/usr/bin/env bash
set -euo pipefail
PORT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done
if [[ "$PORT" == "0" || -z "$PORT" ]]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
export FLASK_ENV=production
exec python3 app.py --port "$PORT"
