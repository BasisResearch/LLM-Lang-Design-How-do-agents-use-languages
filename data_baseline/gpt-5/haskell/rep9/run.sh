#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1-}" == "--port" && -n "${2-}" ]]; then
  PORT="$2"
fi
# Build and run the server
cabal update >/dev/null
cabal build -j todo-app
BIN=$(cabal list-bin todo-app)
exec "$BIN" --port "$PORT"