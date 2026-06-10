#!/bin/bash

PORT=3000
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Build first
cabal build

# Find and run the executable
EXEC_PATH=$(cabal list-bin todo-app)
exec "$EXEC_PATH" --port "$PORT"