#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1:-}" == "--port" ]]; then PORT="$2"; fi
# Implement minimal HTTP via bash+openssl? Use socat tcp-listen
socat TCP-LISTEN:"$PORT",fork,reuseaddr SYSTEM:'./.lake/build/bin/todo --port 0'