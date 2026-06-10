#!/usr/bin/env bash
set -euo pipefail
PORT=8000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

# Build
nasm -f elf64 -g -F dwarf server.asm -o server.o
ld -o server server.o

# Run
exec ./server --port "$PORT"