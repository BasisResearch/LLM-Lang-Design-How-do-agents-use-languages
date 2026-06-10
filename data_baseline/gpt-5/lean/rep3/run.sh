#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1:-}" == "--port" ]]; then
  PORT="$2"
fi
lake build || (lake update && lake build)
# Use socat to run the Lean binary as a per-connection filter.
# The Lean binary reads the HTTP request from stdin and writes the response to stdout.
socat TCP-LISTEN:"$PORT",fork,reuseaddr SYSTEM:"./.lake/build/bin/todo"