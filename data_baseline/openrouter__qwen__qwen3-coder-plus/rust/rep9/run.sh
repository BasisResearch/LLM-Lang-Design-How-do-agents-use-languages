#!/bin/bash

# Parse arguments
port=8080
for i in "$@"; do
    case $i in
        --port)
            port="$2"
            shift 2
            ;;
        *)
            # unknown option
            shift
            ;;
    esac
done

# Build and run the application
cargo build --release
exec ./target/release/todo-app --port "$port"