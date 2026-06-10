#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" ]]; then
  PORT=${2:-3000}
fi
cabal update >/dev/null
cabal build -v0
exe=$(cabal list-bin exe:todoapp)
exec "$exe" --port "$PORT"