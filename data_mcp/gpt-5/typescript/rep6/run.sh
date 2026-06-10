#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ $# -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
# build and run
if [ -f tsconfig.json ]; then
  npx tsc -p tsconfig.json
else
  echo "tsconfig.json not found" >&2
  exit 1
fi
exec node dist/server.js --port "$PORT"
