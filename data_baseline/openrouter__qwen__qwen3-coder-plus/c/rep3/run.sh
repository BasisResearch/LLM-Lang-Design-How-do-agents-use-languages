#!/bin/bash

# Default port
PORT=8080

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift # past argument
            shift # past value
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Install required package for UUID generation
sudo apt-get update
sudo apt-get install -y uuid-dev

# Compile the server
gcc -o server server.c -luuid -lpthread -std=c11 -Wall -Wextra

if [ $? -ne 0 ]; then
    echo "Compilation failed"
    exit 1
fi

echo "Starting server on port $PORT..."

# Run the server with the specified port
./server -p "$PORT"