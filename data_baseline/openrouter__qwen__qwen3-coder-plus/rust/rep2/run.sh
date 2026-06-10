#!/bin/bash

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
            echo "Unknown option $1"
            exit 1
            ;;
    esac
done

# Build and run the server
cargo build --release
if [ $? -eq 0 ]; then
    ./target/release/todo_server --port $PORT
else
    echo "Build failed"
    exit 1
fi