#!/bin/bash

# Todo API Server Runner Script
# Compiles and runs the NASM x86-64 assembly server with port argument support

# Exit on error
set -e

PORT=8080
SERVER_FILE="final_server.asm"
DEBUG=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG=true
            shift
            ;;
        --port)
            PORT="$2"
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                echo "Error: Port must be a number between 1 and 65535" >&2
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "Usage: $0 [--port PORT] [--debug]" >&2
            echo "Default port is 8080" >&2
            exit 1
            ;;
    esac
done

# Ensure dependencies are installed
if ! command -v nasm &> /dev/null; then
    echo "Installing NASM assembler..."
    apt-get update && apt-get install -y nasm
fi

if ! command -v ld &> /dev/null; then
    echo "Installing linker (part of binutils)..."
    apt-get update && apt-get install -y binutils
fi

echo "Compiling server (${SERVER_FILE})..."
nasm -f elf64 "$SERVER_FILE" -o server.o

echo "Linking server executable..."
ld server.o -o server

echo "Compilation complete!"

if [ "$DEBUG" = true ]; then
    echo "Debug mode: Not running server, just compiled"
    ls -la server
elif [ -n "$PORT" ]; then
    echo "Starting server on port $PORT..."
    ./server --port "$PORT"
else
    echo "Starting server on default port 8080..."
    ./server
fi