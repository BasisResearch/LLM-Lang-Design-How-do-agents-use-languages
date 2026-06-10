#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" ]]; then
  PORT=${2:-3000}
fi
# Build with cabal
if [ ! -f "cabal.project" ]; then
  echo "packages: ." > cabal.project
fi
cabal update
cabal build -j
BIN=$(cabal list-bin todo-app)
echo "Starting server on 0.0.0.0:${PORT}"
exec "$BIN" --port "$PORT"
