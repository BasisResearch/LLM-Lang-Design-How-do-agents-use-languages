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

# Compile Java source
javac -cp "lib/*:." $(find src -name "*.java")

if [ $? -ne 0 ]; then
    echo "Compilation failed"
    exit 1
fi

echo "Starting server on port $PORT..."
java -cp "lib/*:src:." com.todoserver.Main --port $PORT