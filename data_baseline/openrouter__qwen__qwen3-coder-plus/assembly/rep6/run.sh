#!/bin/bash

# Build and run the Todo API server

set -e  # Exit on any error

# Check if nasm and ld are available
if ! command -v nasm &>/dev/null; then
    echo "Error: nasm is not installed"
    exit 1
fi

if ! command -v ld &>/dev/null; then
    echo "Error: ld is not installed"
    exit 1
fi

# Parse arguments
PORT=8080

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift
            shift
            ;;
        *)
            echo "Usage: $0 --port PORT"
            exit 1
            ;;
    esac
done

# Compile all assembly files
echo "Compiling assembly files..."
nasm -f elf64 main.asm -o main.o
nasm -f elf64 http_server.asm -o http_server.o
nasm -f elf64 util.asm -o util.o
nasm -f elf64 datastore.asm -o datastore.o
nasm -f elf64 auth.asm -o auth.o
nasm -f elf64 json_helper.asm -o json_helper.o
nasm -f elf64 cookie_utils.asm -o cookie_utils.o
nasm -f elf64 endpoint_handlers.asm -o endpoint_handlers.o

# Link all object files to create the final executable
echo "Linking object files..."
ld main.o http_server.o util.o datastore.o auth.o json_helper.o cookie_utils.o endpoint_handlers.o -o server

# Make the server executable
chmod +x server

# Run the server with specified port
echo "Starting server on port $PORT..."
./server --port $PORT