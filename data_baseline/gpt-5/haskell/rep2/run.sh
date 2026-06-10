#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" ]]; then
  PORT=${2:-3000}
fi
# Build and run
if [[ ! -f "dist-newstyle/cache/plan.json" ]]; then
  cabal update
fi
cabal build todo-server
BIN=$(cabal list-bin todo-server)
exec "$BIN" --port "$PORT"
