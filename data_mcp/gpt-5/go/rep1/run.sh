#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1-}" == "--port" && -n "${2-}" ]]; then
  PORT="$2"
fi

# Build
if ! command -v go >/dev/null 2>&1; then
  echo "Go toolchain not found" >&2
  exit 1
fi

go build -o server .

# Run
exec ./server --port "$PORT"
