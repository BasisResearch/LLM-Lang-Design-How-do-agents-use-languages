#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1:-} == "--port" ]]; then PORT="$2"; fi
# Build Lean binary (not used for serving, but required)
lake build || true
# Start server loop (binds 0.0.0.0:$PORT) via socat
exec ./server_loop.sh --port "$PORT"