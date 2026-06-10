#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" ]]; then
  PORT=${2-8080}
fi
# Build
nasm -f elf64 server.asm -o server.o
ld -o server server.o
# Run
exec ./server --port "$PORT"
