#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
# Build and run
cabal update >/dev/null
cabal build todo-hs >/dev/null
# Find the built binary path
BIN=$(cabal list-bin todo-hs)
exec "$BIN" --port "$PORT"
