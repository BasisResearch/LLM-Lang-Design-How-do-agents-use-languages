#!/bin/bash

# Parse arguments
PORT=8080
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift # past argument
            shift # past value
            ;;
        *)
            echo "Unknown option $1"
            exit 1
            ;;
    esac
done

# Create classes directory
mkdir -p classes

# Download Gson jar if needed, or compile with Java standard libs only
# Since we've refactored the code to work without gson, we can compile directly

# Compile the server
javac -d classes src/com/todo/server/TodoServer.java

if [ $? -ne 0 ]; then
    echo "Compilation failed"
    exit 1
fi

# Run the server
java -cp classes com.todo.server.TodoServer --port $PORT