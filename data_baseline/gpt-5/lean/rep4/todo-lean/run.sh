#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1:-}" == "--port" ]]; then
  PORT="$2"
fi
# Build
lake build
# Run, binding to 0.0.0.0 via our Lean server default
./.lake/build/bin/todo-lean --port "$PORT"
