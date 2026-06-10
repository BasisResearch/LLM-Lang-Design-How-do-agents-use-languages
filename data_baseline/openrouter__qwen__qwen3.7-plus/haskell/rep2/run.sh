#!/bin/bash
set -e

# Build the project
cabal build

# Parse arguments
PORT=3000
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --port) PORT="$2"; shift ;;
    --port=*) PORT="${1#*=}" ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# Find the built executable and run it
EXECUTABLE=$(cabal list-bin todo-api)
exec "$EXECUTABLE" --port "$PORT"
