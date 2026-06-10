#!/bin/bash
set -e

# Build the server
cargo build --release

# Run the server with the provided port argument
./target/release/todo_server "$@"