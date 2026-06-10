#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
# Try to build with tsc if available; otherwise use prebuilt dist/server.js
if command -v tsc >/dev/null 2>&1; then
  tsc -p .
fi
exec node dist/server.js --port "$PORT"
