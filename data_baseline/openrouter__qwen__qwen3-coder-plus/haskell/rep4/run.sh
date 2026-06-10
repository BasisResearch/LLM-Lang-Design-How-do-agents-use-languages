#!/bin/bash

# Build and run the Haskell Todo App server
# Expects --port argument to specify the listening port

# Parse port argument
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --port)
            PORT="$2"
            shift
            shift
            ;;
        *)
            # Unknown option
            shift
            ;;
    esac
done

if [ -z "$PORT" ]; then
    PORT=3000
fi

echo "Building and running server on port $PORT..."

# Ensure necessary cabal packages are installed
cabal update

# Build the project
cabal build

# Run the binary with the specified port
exec cabal run -- todo-app --port $PORT