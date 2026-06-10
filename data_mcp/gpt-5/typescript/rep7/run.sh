#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1-}" == "--port" && -n "${2-}" ]]; then
  PORT="$2"
fi
# Build and run
if [[ -f node_modules/.bin/tsc ]]; then
  npx tsc -p .
else
  npm install
  npx tsc -p .
fi
exec node dist/index.js --port "$PORT"
