#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
# Install deps if node_modules missing
if [[ ! -d node_modules ]]; then
  npm install --silent
fi
# Build TypeScript
npm run build --silent
# Start server
exec node dist/server.js --port "$PORT"
