#!/bin/bash

# Parse command line arguments
PORT=8080
for i in "$@"; do
case $i in
    --port=*)
    PORT="${i#*=}"
    shift
    ;;
    --port)
    PORT="$2"
    shift 2
    ;;
    *)
    # unknown option
    ;;
esac
done

# Build the project
echo "Building the project..."
cargo build --release

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Starting server on port $PORT..."
./target/release/todo_server --port $PORT