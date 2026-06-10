#!/bin/bash
set -e

if [ "$1" != "--port" ] || [ -z "$2" ]; then
    echo "Usage: $0 --port PORT"
    exit 1
fi

PORT=$2

# Assemble and link
nasm -f elf64 server.asm -o server.o
ld server.o -o server

# Run the server
./server --port "$PORT"