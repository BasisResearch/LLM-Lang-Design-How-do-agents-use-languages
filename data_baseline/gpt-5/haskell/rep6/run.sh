#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
# Build and run with cabal
if [[ ! -f cabal.project ]]; then
  cat > cabal.project <<EOF
packages: .
EOF
fi
cabal update
cabal build exe:todo-app
BIN=$(cabal list-bin exe:todo-app)
exec "$BIN" --port "$PORT"
