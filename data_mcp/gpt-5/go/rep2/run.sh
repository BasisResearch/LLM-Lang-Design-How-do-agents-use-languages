#!/bin/bash
set -euo pipefail
PORT=8080
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

go build -o server .
exec ./server --port "$PORT"
