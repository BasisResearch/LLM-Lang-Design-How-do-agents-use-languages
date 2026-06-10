#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ $# -ge 2 && $1 == "--port" ]]; then
  PORT="$2"
fi
# Build
if ! command -v nasm >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y nasm
fi
nasm -f elf64 -g -F dwarf server.asm -o server.o
ld -o server server.o
chmod +x server
# Run
exec ./server --port "$PORT"
