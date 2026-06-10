#!/bin/bash
set -euo pipefail
PORT=8080

# Parse args
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

# Ensure Flask is available
if ! python3 -c 'import flask' >/dev/null 2>&1; then
  echo "Installing Flask..." >&2
  pip3 install --no-cache-dir -q Flask
fi

exec python3 server.py --port "$PORT"