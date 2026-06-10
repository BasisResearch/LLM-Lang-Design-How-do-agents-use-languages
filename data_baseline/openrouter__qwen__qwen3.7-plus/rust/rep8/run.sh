#!/bin/bash
set -e

PORT=3000
if [[ "$1" == "--port" && -n "$2" ]]; then
    PORT=$2
fi

cargo build --release
./target/release/todo_app --port "$PORT"
