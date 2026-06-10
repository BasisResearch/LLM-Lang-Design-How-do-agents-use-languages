#!/bin/bash
set -euo pipefail
PORT=8000

# Parse --port PORT
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

export FLASK_ENV=production
exec python3 app.py --port "$PORT"
