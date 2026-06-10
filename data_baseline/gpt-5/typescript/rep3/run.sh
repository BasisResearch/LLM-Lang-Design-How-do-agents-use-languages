#!/usr/bin/env bash
set -euo pipefail
PORT=3000
# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *)
      echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

# Build and run
if [ -f tsconfig.json ]; then
  npx tsc
else
  echo "tsconfig.json not found" >&2
  exit 1
fi

exec node dist/server.js --port "$PORT"
