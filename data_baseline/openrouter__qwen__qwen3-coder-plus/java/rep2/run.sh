#!/bin/bash

# Compile and run the todo server

# Parse command line arguments
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

# Compile the Java files
echo "Compiling Java source files..."
javac -cp src src/com/todoserver/*.java -d bin

if [ $? -ne 0 ]; then
    echo "Compilation failed!"
    exit 1
fi

echo "Compilation successful!"

# Run the server
echo "Starting server on port $PORT..."
java -cp bin com.todoserver.Main --port $PORT