#!/bin/bash

# Parse command line arguments
port=3000
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      port="$2"
      shift
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Install dependencies
cabal update
cabal build

# Run the executable with the port argument
exec cabal run exe:todo-app -- --port $port