#!/usr/bin/env bash
set -euo pipefail
PORT=3000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Build and run
if [ -f package.json ]; then
  npm install --silent
fi
npm run build --silent
# Replace shell with node so that killing this PID stops server
exec node dist/server.js --port "$PORT"
