#!/bin/bash
set -e
nasm -f elf64 server.asm -o server.o
ld server.o -o server
PORT=8080
if [ "$1" = "--port" ] && [ -n "$2" ]; then
    PORT=$2
fi
exec ./server --port $PORT