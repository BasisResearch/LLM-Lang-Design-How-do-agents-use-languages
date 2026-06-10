#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1:-} == "--port" ]]; then
  PORT=${2:-8080}
fi
# Ensure nasm is installed
if ! command -v nasm >/dev/null 2>&1; then
  echo "Installing nasm..." >&2
  sudo apt-get update -y && sudo apt-get install -y nasm
fi
# Build
nasm -f elf64 -g -F dwarf -o server.o server.asm
ld -o server server.o
# Run
exec ./server --port "$PORT"
