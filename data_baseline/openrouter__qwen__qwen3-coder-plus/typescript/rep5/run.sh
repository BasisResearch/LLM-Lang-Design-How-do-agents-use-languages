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
            echo "Unknown option $1"
            exit 1
            ;;
    esac
done

# Use default port 3000 if not specified
PORT=${PORT:-3000}

# Set NODE_ENV to production to ensure tsx handles paths correctly
NODE_PATH=. tsx server.ts --port "$PORT"