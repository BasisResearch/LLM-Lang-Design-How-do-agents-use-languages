#!/bin/bash

# Parse arguments
PORT=3000
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
    npm install
fi

# Run the server with tsx
npx tsx server.ts --port $PORT