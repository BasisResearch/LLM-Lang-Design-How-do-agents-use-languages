#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" ]]; then
  PORT=${2-8080}
fi
# Build
if ! command -v nasm >/dev/null 2>&1; then
  echo "Installing nasm and build tools..." >&2
  sudo apt-get update -y
  sudo apt-get install -y nasm
fi
nasm -f elf64 -g -F DWARF server.asm -o server.o
ld -o server server.o
chmod +x server
./server --port "$PORT"