#!/bin/bash

# Parse command line arguments
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

# Default to port 8080 if not specified
if [ -z "$PORT" ]; then
    PORT=8080
fi

# Start the server
python3 server.py --port $PORT