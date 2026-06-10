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
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if port is provided
if [ -z "$PORT" ]; then
    echo "Usage: $0 --port PORT"
    exit 1
fi

# Start the server
node server.js --port $PORT