#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "$#" -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
# Install deps if node_modules missing
if [[ ! -d node_modules ]]; then
  npm install --silent
fi
# Build TypeScript
npm run build --silent
# Run server binding to 0.0.0.0:PORT via CLI arg
node dist/server.js --port "$PORT"
