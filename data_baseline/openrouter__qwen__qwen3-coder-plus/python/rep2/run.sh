#!/bin/bash

# Parse command line arguments
PORT=8000

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

# Run the Python server
python3 todo_app_server.py --port "$PORT"