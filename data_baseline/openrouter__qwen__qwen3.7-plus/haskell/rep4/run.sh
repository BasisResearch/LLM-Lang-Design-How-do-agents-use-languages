#!/bin/bash
set -e

# Parse port argument
PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Build the server
cabal build

# Run the server
exec cabal run todo-server -- --port "$PORT"
