#!/bin/bash

# Parse command line arguments
PORT=3000

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift # past argument
            shift # past value
            ;;
        *)
            echo "Unknown option $1"
            exit 1
            ;;
    esac
done

# Export NODE_OPTIONS if not set to avoid warnings
export NODE_OPTIONS="${NODE_OPTIONS:-}"

# Run the server
node server.js --port "$PORT"