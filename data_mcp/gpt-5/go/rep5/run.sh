#!/usr/bin/env bash
set -euo pipefail
PORT=""
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
if [[ -z "${PORT}" ]]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
# Build
if [[ ! -f go.mod ]]; then
  go mod init todoapp >/dev/null 2>&1 || true
fi
go build -o server .
# Run
exec ./server --port "${PORT}"
