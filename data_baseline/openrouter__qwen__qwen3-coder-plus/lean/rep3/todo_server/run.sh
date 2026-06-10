#!/bin/bash

# Parse command line arguments
PORT=8080

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

# Ensure we're in the project directory
cd "$(dirname "$0")"

# Build the server with Lake
echo "Building server..."
lake build

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Execute the built binary with the given port
./.lake/build/bin/server --port=$PORT