#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1:-} == "--port" && -n ${2:-} ]]; then
  PORT=$2
fi

# Ensure deps
if ! command -v gcc >/dev/null 2>&1; then
  echo "gcc not found" >&2
  exit 1
fi

# Install required libraries if not present
need_install=false
pkg-config --exists jansson || need_install=true
if $need_install; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y libjansson-dev
  else
    echo "Please install libjansson-dev" >&2
    exit 1
  fi
fi

gcc -O2 -Wall -Wextra -o server main.c $(pkg-config --cflags --libs jansson)
./server --port "$PORT"
