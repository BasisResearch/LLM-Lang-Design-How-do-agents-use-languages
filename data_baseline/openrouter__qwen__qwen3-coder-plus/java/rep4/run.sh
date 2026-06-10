#!/bin/bash

# Parse command-line arguments
PORT=8080

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Compile Java source files
echo "Compiling server..."
mkdir -p bin

javac -d bin src/com/todoserver/*.java

if [ $? -ne 0 ]; then
    echo "Compilation failed!"
    exit 1
fi

echo "Starting server on port $PORT..."

# Run the server
java -cp bin com.todoserver.Main --port $PORT