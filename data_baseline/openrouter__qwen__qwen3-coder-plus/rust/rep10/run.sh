#!/bin/bash

# Build the project and run the server with the given port
cargo build --release

if [ $? -ne 0 ]; then
    echo "Build failed"
    exit 1
fi

# Pass all arguments to the binary
./target/release/todo-app "$@"