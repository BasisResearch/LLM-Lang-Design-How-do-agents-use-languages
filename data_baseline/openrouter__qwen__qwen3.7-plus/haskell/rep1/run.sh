#!/bin/bash
set -e

PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

echo "Building with cabal..."
cabal build

echo "Starting server on port $PORT..."
EXEC=$(cabal list-bin todo-server)
exec "$EXEC" --port "$PORT"
