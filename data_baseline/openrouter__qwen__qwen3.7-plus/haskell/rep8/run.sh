#!/bin/bash
set -e

# Build the project
cabal build

# Find the executable path
EXEC_PATH=$(cabal list-bin todo-app)

# Run the executable with passed arguments
exec "$EXEC_PATH" "$@"