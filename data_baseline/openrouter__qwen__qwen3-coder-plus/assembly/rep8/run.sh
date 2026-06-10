#!/bin/bash

# Run the Todo API server

set -e

PROGRAM_NAME="server"

# Check dependencies
if ! command -v nasm &> /dev/null; then
    echo "Error: nasm is not installed" >&2
    exit 1
fi

if ! command -v ld &> /dev/null; then
    echo "Error: ld is not installed" >&2
    exit 1
fi

# Default port
PORT="3000"
ASSEMBLY_FILE="todo_server.asm"

# Parse command line flags
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--port PORT]"
            exit 1
            ;;
    esac
done

echo "Building server from $ASSEMBLY_FILE..."
nasm -f elf64 "$ASSEMBLY_FILE" -o "${PROGRAM_NAME}.o"
ld "${PROGRAM_NAME}.o" -o "$PROGRAM_NAME"

echo "Starting server on port $PORT..."
exec "./$PROGRAM_NAME" --port "$PORT"
