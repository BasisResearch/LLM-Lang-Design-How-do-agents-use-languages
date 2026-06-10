#!/bin/bash
set -euo pipefail
PORT=8080
if [[ "$#" -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
make
exec ./server --port "$PORT"
