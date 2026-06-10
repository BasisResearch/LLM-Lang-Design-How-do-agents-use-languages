#!/usr/bin/env bash
set -euo pipefail
PORT=3000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2 ;;
    *)
      shift ;;
  esac
done

# Install deps if needed
if [ ! -d node_modules ]; then
  npm install --silent
fi

# Build and run
npx tsc -p tsconfig.json
node dist/server.js --port "$PORT"
