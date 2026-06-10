#!/bin/bash

echo "Attempting simple build..."

# Try to compile directly with elan if needed
if command -v lean &> /dev/null; then
    echo "Lean found, attempting build with lake"
else
    echo "Setting up Lean environment"
    elan self update
fi

echo "Building project..."
lake update
lake build

if [ $? -eq 0 ]; then
    echo "Build successful!"
    
    # Parse command line arguments
    PORT=8080

    while [[ $# -gt 0 ]]; do
        case $1 in
            --port)
                PORT="$2"
                shift
                shift
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    echo "Starting server on port $PORT..."

    # Run the application
    ./.lake/build/bin/todo_api --port "$PORT"
else
    echo "Build failed, reviewing configuration..."
    echo "Current directory:" $(pwd)
    echo "Files:"
    ls -la
    echo "Lake build output above."
fi