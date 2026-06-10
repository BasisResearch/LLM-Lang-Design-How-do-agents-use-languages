#!/usr/bin/env bash
set -euo pipefail
PORT=3000
# parse --port PORT
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown argument: $1" >&2; exit 1;;
  esac
done
# Install deps if node_modules missing
if [ ! -d node_modules ]; then
  npm install --silent
fi
# Build TypeScript
npm run build --silent
# Run server (replace shell with node so signals propagate)
exec node dist/index.js --port "$PORT"
