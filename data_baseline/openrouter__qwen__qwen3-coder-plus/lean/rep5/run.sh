#!/bin/bash

# Parse command line arguments
PORT=8080
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Build the project with lake
echo "Building project..."
lake build

if [ $? -ne 0 ]; then
    echo "Build failed"
    exit 1
fi

echo "Build successful, starting server on port $PORT..."
./build/bin/todo_app --port $PORT