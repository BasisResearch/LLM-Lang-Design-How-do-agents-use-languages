#!/bin/bash

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Set default port if not specified
PORT=${PORT:-3000}

# Run the server using Node.js
exec node server.js --port $PORT