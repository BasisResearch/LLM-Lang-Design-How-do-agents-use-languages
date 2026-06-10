#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ ${1-} == "--port" ]]; then
  PORT=${2}
fi
cabal build -j
BIN=$(cabal list-bin todo-app 2>/dev/null || echo "")
if [[ -z "$BIN" ]]; then
  # fallback for older cabal
  BIN=$(cabal exec --verbose=0 -- which todo-app || true)
fi
if [[ -z "$BIN" ]]; then
  echo "Could not find built binary."
  exit 1
fi
exec "$BIN" --port "$PORT"
