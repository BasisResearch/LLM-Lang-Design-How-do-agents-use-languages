#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
# Build TypeScript
npm run build --silent
# Run server
node dist/server.js --port "$PORT"
