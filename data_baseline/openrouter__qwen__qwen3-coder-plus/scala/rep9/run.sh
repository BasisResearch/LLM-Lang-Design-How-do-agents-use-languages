#!/bin/bash

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

# Run the server with the specified port
exec scala-cli run . -- Main.scala -- --port $PORT
