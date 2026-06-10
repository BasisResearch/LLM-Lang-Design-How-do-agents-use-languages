#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "$#" -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
cd "$(dirname "$0")"
lake build
./.lake/build/bin/todo --port "$PORT"
