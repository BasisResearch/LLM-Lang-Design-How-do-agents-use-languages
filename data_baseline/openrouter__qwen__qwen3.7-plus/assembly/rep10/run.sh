#!/bin/bash
PORT=8080
if [ "$1" == "--port" ] && [ -n "$2" ]; then
    PORT=$2
fi

echo "Compiling server..."
nasm -f elf64 server.asm -o server.o
if [ $? -ne 0 ]; then
    echo "NASM compilation failed"
    exit 1
fi

echo "Linking server..."
ld server.o -o server
if [ $? -ne 0 ]; then
    echo "LD linking failed"
    exit 1
fi

echo "Starting server on port $PORT..."
exec ./server --port "$PORT"
