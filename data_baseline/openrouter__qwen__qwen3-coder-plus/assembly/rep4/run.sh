#!/bin/bash

# Todo API Server Run Script
# Builds and runs the x86_64 NASM server

# Check for required arguments
if [ "$1" != "--port" ] || [ -z "$2" ]; then
    echo "Usage: $0 --port PORT"
    exit 1
fi

port=$2

# Install necessary tools if on Ubuntu
if command -v apt-get >/dev/null 2>&1; then
    if ! command -v nasm >/dev/null 2>&1 || ! command -v ld >/dev/null 2>&1; then
        echo "Installing nasm and linker..."
        sudo apt-get update
        sudo apt-get install -y nasm binutils
    fi
elif command -v yum >/dev/null 2>&1; then
    if ! command -v nasm >/dev/null 2>&1 || ! command -v ld >/dev/null 2>&1; then
        echo "Installing nasm and linker..."
        sudo yum install -y nasm glibc-static
    fi
else
    # Make sure nasm and ld exist
    if ! command -v nasm >/dev/null 2>&1; then
        echo "Error: nasm is required but not installed."
        exit 1
    fi
    if ! command -v ld >/dev/null 2>&1; then
        echo "Error: ld (linker) is required but not installed."
        exit 1
    fi
fi

# Assemble and link
echo "Assembling and linking server..."

nasm -f elf64 final_todo_server.asm -o final_todo_server.o
if [ $? -ne 0 ]; then
    echo "Assembly failed!"
    exit 1
fi

ld final_todo_server.o -o final_todo_server
if [ $? -ne 0 ]; then
    echo "Linking failed!"
    exit 1
fi

# Check if executable exists
if [ ! -f "./final_todo_server" ]; then
    echo "Build failed: final_todo_server executable not created"
    exit 1
fi

echo "Server built successfully."
echo "Starting server on port ${port}..."

# Run the server with the port
exec ./final_todo_server --port "${port}"