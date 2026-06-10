#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
# Build
lake build
# Run binary
exe=".lake/build/bin/todoapp"
if [[ ! -x "$exe" ]]; then
  echo "Executable not found: $exe" >&2
  exit 1
fi
exec "$exe" --port "$PORT"
