#!/bin/bash

# Install scala-cli if not already installed
if ! command -v scala-cli &> /dev/null; then
    echo "Installing scala-cli..."  
    curl -sSLf "https://scala-cli.virtuslab.org/get" | bash
    export PATH="$HOME/.scala-cli/bin:$PATH"
fi

# Parse arguments
PORT=8080
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

echo "Starting server on port $PORT..."
scala-cli run TodoServer.scala -- --port $PORT