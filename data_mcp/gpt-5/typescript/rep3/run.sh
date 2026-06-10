#!/usr/bin/env bash
set -euo pipefail
PORT=3000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done

# Install deps if node_modules missing
if [ ! -d node_modules ]; then
  npm install --silent
fi

# Build TypeScript
npx tsc -p tsconfig.json

# Start server
node dist/server.js --port "$PORT"
