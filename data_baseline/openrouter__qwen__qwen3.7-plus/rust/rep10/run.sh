#!/bin/bash
set -e

PORT=3000
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

cargo build --release
./target/release/todo-server --port "$PORT"
