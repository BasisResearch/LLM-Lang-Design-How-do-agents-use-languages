#!/bin/bash
set -euo pipefail
PORT=8000
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

exec python3 -m uvicorn main:app --host 0.0.0.0 --port "$PORT"
