#!/bin/bash
set -euo pipefail
PORT=3000
if [[ "${1-}" == "--port" ]]; then
  PORT="$2"
fi
# Install deps if node_modules missing
if [[ ! -d node_modules ]]; then
  npm install --silent
fi
npm run build --silent
exec node dist/server.js --port "$PORT"
