#!/usr/bin/env bash
set -euo pipefail
PORT=""
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
else
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi

# Install dependencies if missing
if ! command -v gcc >/dev/null 2>&1; then
  echo "Installing build tools..." >&2
  sudo apt-get update && sudo apt-get install -y build-essential
fi
if ! pkg-config --exists libmicrohttpd; then
  echo "Installing libmicrohttpd..." >&2
  sudo apt-get update && sudo apt-get install -y libmicrohttpd-dev
fi
if ! pkg-config --exists jansson; then
  echo "Installing jansson..." >&2
  sudo apt-get update && sudo apt-get install -y libjansson-dev
fi

make
./server --port "$PORT"
