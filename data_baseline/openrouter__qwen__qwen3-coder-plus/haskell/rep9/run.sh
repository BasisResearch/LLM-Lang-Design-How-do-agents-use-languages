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
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

if [ -z "$PORT" ]; then
    echo "Usage: $0 --port PORT"
    exit 1
fi

# Build and install dependencies first
set -e
cabal update
cabal build

echo "Starting server on port $PORT..."

# Run the built executable with the port argument
cabal run todo-app -- --port $PORT