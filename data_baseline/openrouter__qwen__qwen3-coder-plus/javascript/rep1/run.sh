#!/bin/bash

# Parse arguments
PORT=8080

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

# Check if PORT is a number 
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    echo "Port must be a number"
    exit 1
fi

# Start the server
node server.js --port $PORT