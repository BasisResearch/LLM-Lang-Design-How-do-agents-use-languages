#!/bin/bash
set -euo pipefail
PORT=8080
if [[ "$#" -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
if ! command -v gcc >/dev/null 2>&1; then
  echo "gcc not found. Installing build-essential..." >&2
  sudo apt-get update && sudo apt-get install -y build-essential
fi

gcc -Wall -Wextra -O2 -pthread -o server main.c
exec ./server --port "$PORT"
