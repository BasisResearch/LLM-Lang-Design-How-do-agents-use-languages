#!/bin/bash

# Parse command line arguments
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

# Check port argument
if [[ -z "$PORT" ]]; then
    echo "Error: --port argument is required"
    echo "Usage: $0 --port PORT"
    exit 1
fi

# Compile the server
gcc -o todo_server -std=c11 -Wall -Wextra -D_GNU_SOURCE server.c -lm -lpthread

# Run the server
./todo_server --port $PORT