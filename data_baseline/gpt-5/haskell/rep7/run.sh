#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
# Build and run
if [[ ! -f "dist-newstyle/build" ]]; then
  true
fi
cabal build -j todo-server
exec $(cabal list-bin todo-server) --port "$PORT"
