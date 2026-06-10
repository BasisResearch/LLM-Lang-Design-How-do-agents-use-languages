#!/bin/bash
# Script to compile assembly server and test functionality

set -e  # Exit on error

# Check if nasm and linker exist
if ! command -v nasm & >/dev/null; then
    echo "Installing nasm..."
    sudo apt-get update && sudo apt-get install -y nasm
fi

if ! command -v ld & >/dev/null; then
    echo "Install binutils for linker..."
    sudo apt-get update && sudo apt-get install -y binutils
fi

echo "Compiling server assembly code..."

# Try compiling the simpler modules first
echo "Compiling util.asm..."
if nasm -f elf64 util.asm -o util.o; then
    echo "✓ util.asm compiled successfully"
else
    echo "✗ FAILED to compile util.asm"
    exit 1
fi

echo "Compiling http_server.asm..."
if nasm -f elf64 http_server.asm -o http_server.o; then
    echo "✓ http_server.asm compiled successfully"
else
    echo "✗ FAILED to compile http_server.asm"
    exit 1
fi

echo "Compiling datastore.asm..." 
if nasm -f elf64 datastore.asm -o datastore.o; then
    echo "✓ datastore.asm compiled successfully"
else
    echo "✗ FAILED to compile datastore.asm"
    exit 1
fi

echo "Compiling auth.asm..."
if nasm -f elf64 auth.asm -o auth.o; then
    echo "✓ auth.asm compiled successfully"
else
    echo "✗ FAILED to compile auth.asm"
    exit 1
fi

echo "Compiling json_helper.asm..."
if nasm -f elf64 json_helper.asm -o json_helper.o; then
    echo "✓ json_helper.asm compiled successfully"
else
    echo "✗ FAILED to compile json_helper.asm" 
    exit 1
fi

echo "Compiling cookie_utils.asm..."
if nasm -f elf64 cookie_utils.asm -o cookie_utils.o; then
    echo "✓ cookie_utils.asm compiled successfully"
else
    echo "✗ FAILED to compile cookie_utils.asm"
    exit 1
fi

echo "Compiling endpoint_handlers.asm..."
if nasm -f elf64 endpoint_handlers.asm -o endpoint_handlers.o; then
    echo "✓ endpoint_handlers.asm compiled successfully"
else
    echo "✗ FAILED to compile endpoint_handlers.asm"
    exit 1
fi

echo "Compiling main.asm..."
if nasm -f elf64 main.asm -o main.o; then
    echo "✓ main.asm compiled successfully"
else
    echo "✗ FAILED to compile main.asm"
    exit 1
fi

echo "Linking all object files..."
if ld main.o http_server.o util.o datastore.o auth.o json_helper.o cookie_utils.o endpoint_handlers.o -o server; then
    echo "✓ Server linked successfully"
    chmod +x server
else
    echo "✗ FAILED to link server"
    exit 1
fi

echo ""
echo "🎉 Server compilation completed successfully!"
echo "Binary: ./server (executable)"
echo "Run: ./server --port 8080"