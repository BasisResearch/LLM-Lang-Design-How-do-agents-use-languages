#!/bin/bash

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "$PORT" ]; then
    echo "Usage: $0 --port PORT"
    exit 1
fi

# Compile the server
gcc -o server server.c -luuid -lpthread

if [ $? -ne 0 ]; then
    echo "Compilation failed"
    exit 1
fi

# Run the server
./server --port $PORT