#!/bin/bash
set -e  # Exit on any error

if [ "$1" = "--port" ] && [ -n "$2" ]; then
    PORT="$2"
elif [[ "$1" =~ ^[0-9]+$ ]]; then
    # Allow just passing the numeric port directly
    PORT="$1"
else
    echo "Usage: $0 --port PORT"
    echo "   or: $0 PORT"
    exit 1
fi

# Validate port number
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "Error: Port must be a number between 1 and 65535"
    exit 1
fi

echo "Starting server on port $PORT"
exec python3 server.py --port "$PORT"