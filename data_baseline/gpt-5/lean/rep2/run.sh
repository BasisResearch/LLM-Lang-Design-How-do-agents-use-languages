#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1-}" == "--port" ]]; then
  PORT="$2"
fi
cd todo-lean
lake build
# Run the built executable, binding to 0.0.0.0:PORT is handled by the server implementation
./.lake/build/bin/todo-lean --port "$PORT"
