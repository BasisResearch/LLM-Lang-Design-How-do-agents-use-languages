#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1-}" == "--port" && -n "${2-}" ]]; then
  PORT="$2"
fi
exec node server.js --port "$PORT"