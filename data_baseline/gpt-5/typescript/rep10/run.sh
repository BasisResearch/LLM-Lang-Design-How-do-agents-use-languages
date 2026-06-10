#!/usr/bin/env bash
set -euo pipefail
PORT=3000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done
# Always install to ensure dev dependencies for TypeScript are present
npm install --silent
npm run build --silent
node dist/server.js --port "$PORT"
