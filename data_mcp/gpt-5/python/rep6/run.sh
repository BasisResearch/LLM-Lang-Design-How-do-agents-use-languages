#!/bin/bash
set -euo pipefail
PORT=""

# Parse --port argument
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${PORT}" ]]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi

# Ensure dependencies
if ! python3 -c "import flask" >/dev/null 2>&1; then
  python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
  python3 -m pip install flask >/dev/null 2>&1
fi

exec python3 server.py --port "$PORT"
