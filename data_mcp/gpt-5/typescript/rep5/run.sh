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

# Build TypeScript and run compiled server to avoid runtime transpilation issues
if [[ ! -f "dist/server.js" ]] || [[ src/server.ts -nt dist/server.js ]]; then
  npx tsc -p tsconfig.json
fi
node dist/server.js --port "$PORT"
