#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1:-}" == "--port" ]]; then
  PORT="$2"
fi
# Build
if ! command -v go >/dev/null 2>&1; then
  echo "Go is required to build this server" >&2
  exit 1
fi
GOFLAGS=${GOFLAGS:-}
# tidy modules
go mod tidy
# build
GOOS=${GOOS:-} GOARCH=${GOARCH:-} go build -o server .
# run
exec ./server --port "$PORT"
