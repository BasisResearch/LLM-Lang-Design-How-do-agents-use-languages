#!/usr/bin/env bash
set -euo pipefail

PORT=0
if [[ $# -ge 2 && $1 == "--port" ]]; then
  PORT=$2
else
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi

# Install dependencies if node_modules missing
if [[ ! -d node_modules ]]; then
  npm install --silent
fi

# Build TypeScript
npm run build --silent

# Run server
node dist/server.js --port "$PORT"
