#!/bin/bash

PORT=8080

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift
      shift
      ;;
    *)
      # Unknown option
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Ensure we're in the right directory
cd "$(dirname "$0")"

# Download required JARs if they don't exist
if [ ! -f "gson-2.8.9.jar" ]; then
  echo "Downloading Gson library..."
  curl -L -o gson-2.8.9.jar https://repo1.maven.org/maven2/com/google/code/gson/gson/2.8.9/gson-2.8.9.jar
fi

# Compile the Java source code
echo "Compiling Java source files..."
javac -cp ".:gson-2.8.9.jar" src/com/todo/server/*.java

# Run the server with the specified port
echo "Starting server on port $PORT..."
java -cp ".:gson-2.8.9.jar:src" com.todo.server.TodoServer --port $PORT