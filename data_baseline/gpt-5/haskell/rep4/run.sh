#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" ]]; then
  PORT=${2:-3000}
fi
# Build and run with cabal
if [[ ! -f cabal.project ]]; then
  echo 'packages: ./' > cabal.project
fi
cabal build exe:todo-app
BIN=$(cabal list-bin exe:todo-app)
exec "$BIN" --port "$PORT"