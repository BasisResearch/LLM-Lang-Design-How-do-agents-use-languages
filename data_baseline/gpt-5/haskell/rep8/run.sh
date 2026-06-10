#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" ]]; then
  PORT="$2"
fi
# Build and run with cabal
cabal update >/dev/null
cabal build >/dev/null
BIN=$(cabal list-bin todo-server 2>/dev/null || true)
if [[ -z "$BIN" ]]; then
  # fallback for older cabal: find the binary in dist-newstyle
  BIN=$(find dist-newstyle -type f -name todo-server -perm -111 | head -n1)
fi
if [[ -z "$BIN" ]]; then
  echo "Failed to locate built binary" >&2
  exit 1
fi
exec "$BIN" --port "$PORT"
