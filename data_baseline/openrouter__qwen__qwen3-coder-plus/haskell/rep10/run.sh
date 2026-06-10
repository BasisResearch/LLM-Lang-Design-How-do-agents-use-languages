#!/bin/bash

# Make sure cabal build is working properly
cabal update
cabal build

if [ $? -eq 0 ]; then
    echo "Build successful. Starting server..."
    
    # Extract port from command line if provided or use default 8080
    PORT=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --port)
                PORT="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    
    if [ -z "$PORT" ]; then
        PORT=8080
    fi
    
    echo "Starting server on port $PORT"
    # Execute using cabal run with the correct executable name
    exec cabal run rep10-exe -- --port "$PORT"
else
    echo "Build failed"
    exit 1
fi