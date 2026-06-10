#!/bin/bash
set -e

# Build the project
cabal build

# Find the executable
EXEC=$(cabal list-bin todo-server)

# Run with provided arguments (e.g., --port 8080)
exec "$EXEC" "$@"
