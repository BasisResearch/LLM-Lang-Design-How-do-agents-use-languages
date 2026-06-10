#!/bin/bash

set -e  # Exit on any error

# Parse arguments for --port, defaulting to 3000
PORT=3000
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

echo "Starting server on port $PORT..."

# Build if needed, and run the executable
exec $(cabal list-bin exe:rep3-exe) -- --port "$PORT"