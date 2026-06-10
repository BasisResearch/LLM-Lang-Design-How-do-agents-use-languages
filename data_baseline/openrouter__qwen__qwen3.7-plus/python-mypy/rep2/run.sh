#!/bin/bash

PORT=8000

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

uvicorn main:app --host 0.0.0.0 --port "$PORT"
