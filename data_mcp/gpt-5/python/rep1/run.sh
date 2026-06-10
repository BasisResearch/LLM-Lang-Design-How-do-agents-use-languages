#!/bin/bash
set -euo pipefail
PORT=8000
# Parse --port PORT
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      shift
      PORT="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done
exec python3 server.py --port "$PORT"