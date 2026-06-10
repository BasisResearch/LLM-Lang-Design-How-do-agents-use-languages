#!/bin/bash

# Parse command line arguments
port=8080
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            port="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
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

# Run the server on specified port
./target/release/todo-server --port "$port"