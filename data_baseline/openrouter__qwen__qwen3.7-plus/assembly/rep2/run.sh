#!/bin/bash
set -e

# Parse arguments
PORT=8080
for i in "$@"; do
  if [ "$i" == "--port" ]; then
    shift
    PORT="$1"
    break
  fi
done

# Compile and link
echo "Compiling server..."
nasm -f elf64 server.asm -o server.o
ld server.o -o server
chmod +x server

echo "Starting server on port $PORT..."
exec ./server "$PORT"