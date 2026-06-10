#!/usr/bin/env bash
set -euo pipefail

PORT=8080

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

# Ensure dependencies
GO111MODULE=on go mod tidy

# Build
GO111MODULE=on go build -o server .

# Run
exec ./server --port "$PORT"
