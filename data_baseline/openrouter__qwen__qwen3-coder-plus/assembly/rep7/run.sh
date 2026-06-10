#!/bin/bash

# Todo API Server Runner
# Usage: ./run.sh --port PORT

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 --port PORT"
            exit 1
            ;;
    esac
done

# Validate port argument
if [[ -z "$PORT" ]] || ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 ]] || [[ "$PORT" -gt 65535 ]]; then
    echo "Error: Invalid port number. Port must be between 1 and 65535."
    exit 1
fi

echo "Compiling server..."
gcc -o todo_server todo_server_final.c -Wall -std=c11

if [ $? -ne 0 ]; then
    echo "Compilation failed!"
    exit 1
fi

echo "Starting server on 0.0.0.0:$PORT..."
./todo_server --port $PORT