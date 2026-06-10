#!/bin/bash
set -euo pipefail
PORT=8000

# Parse --port argument
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT=$2
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Pure standard library server; no dependencies needed
exec python3 server.py --port "$PORT"