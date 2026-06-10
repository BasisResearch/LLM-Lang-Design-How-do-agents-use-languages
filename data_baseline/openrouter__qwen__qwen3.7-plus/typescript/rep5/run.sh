#!/bin/bash
PORT=3000
if [ "$1" = "--port" ] && [ -n "$2" ]; then
  PORT="$2"
fi
npx tsc
node dist/src/index.js --port "$PORT"
