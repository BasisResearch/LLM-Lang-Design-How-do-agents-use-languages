#!/usr/bin/env bash
set -euo pipefail
PORT=8000
# parse args --port PORT
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing PORT after --port" >&2
        exit 1
      fi
      PORT=$1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

exec python3 app.py --port "$PORT"