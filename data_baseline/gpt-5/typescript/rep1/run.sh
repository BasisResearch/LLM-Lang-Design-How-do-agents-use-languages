#!/bin/bash
set -euo pipefail
PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${PORT}" ]]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi

# Install deps if node_modules missing
if [[ ! -d node_modules ]]; then
  npm install --silent
fi

# Build TypeScript
npm run build --silent

# Run server
node dist/server.js --port "${PORT}"
