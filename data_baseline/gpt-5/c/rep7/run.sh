#!/usr/bin/env bash
set -euo pipefail
PORT=""
if [[ "$#" -ge 2 && "$1" == "--port" ]]; then
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

# Check for libraries
missing=()
ldconfig -p | grep -q libmicrohttpd || missing+=(libmicrohttpd-dev)
ldconfig -p | grep -q libjansson || missing+=(libjansson-dev)
ldconfig -p | grep -q libuuid || missing+=(uuid-dev)
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Installing dependencies: ${missing[*]}" >&2
  sudo apt-get update && sudo apt-get install -y "${missing[@]}"
fi

make
./server --port "$PORT"
