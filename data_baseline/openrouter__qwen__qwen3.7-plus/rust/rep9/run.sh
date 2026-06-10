#!/bin/bash
PORT=8080

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
        *) ;;
    esac
    shift
done

cargo build --release
./target/release/todo_app --port "$PORT"