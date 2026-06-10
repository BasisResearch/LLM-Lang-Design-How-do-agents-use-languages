#!/bin/bash

# Parse the --port argument
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

# Build the project
cargo build --release

if [ $? -ne 0 ]; then
    echo "Build failed"
    exit 1
fi

# Run the server with the provided port
exec ./target/release/todo-app --port ${PORT:-8080}