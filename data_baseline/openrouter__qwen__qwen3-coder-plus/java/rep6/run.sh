#!/bin/bash

# Parse command line arguments
PORT=8080
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--port PORT]"
            exit 1
            ;;
    esac
done

# Compile the Java server
javac -cp . Server.java

if [ $? -ne 0 ]; then
    echo "Compilation failed"
    exit 1
fi

echo "Starting server on port $PORT"
java -cp . Server --port $PORT