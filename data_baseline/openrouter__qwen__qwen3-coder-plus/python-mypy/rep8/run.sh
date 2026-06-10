#!/bin/bash

# Default port
PORT=8000

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Start the server
exec python3 server.py --port "$PORT"