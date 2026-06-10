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
cargo build --release

# Check if build succeeded
if [ $? -ne 0 ]; then
    echo "Build failed"
    exit 1
fi

# Run the server with the specified port
./target/release/todo-api --port $PORT