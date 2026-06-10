#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" && -n ${2-} ]]; then
  PORT=$2
fi
# Build
if ! command -v nasm >/dev/null; then
  echo "Installing nasm..." >&2
  sudo apt-get update -y && sudo apt-get install -y nasm
fi
nasm -f elf64 -g -F dwarf -o server.o server.asm
ld -o server server.o
chmod +x server
# Run
exec ./server --port "$PORT"
