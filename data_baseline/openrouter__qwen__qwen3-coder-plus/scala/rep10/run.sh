#!/bin/bash

# Parse command line arguments
while [[ $# -gt 0 ]]; do
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

# Set default port if not set
if [ -z "$PORT" ]; then
    PORT=8080
fi

# Run the server with Scala CLI
SCALA_CLI_ARGS="--port $PORT" scala-cli run Main.scala