#!/bin/bash
set -euo pipefail
PORT=3000
if [[ "${1-}" == "--port" ]]; then
  PORT="$2"
fi
# install deps if node_modules missing
if [[ ! -d node_modules ]]; then
  npm install --silent
fi
# build TS
npm run build --silent
# run server binding 0.0.0.0
exec node dist/server.js --port "$PORT"
