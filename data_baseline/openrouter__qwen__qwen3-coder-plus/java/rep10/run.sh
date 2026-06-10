#!/bin/bash

# Set default port
PORT=8080

# Parse command line arguments
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

# Compile the Java source files
javac Server.java

if [ $? -ne 0 ]; then
  echo "Compilation failed"
  exit 1
fi

echo "Starting server on port $PORT..."
java -cp . Server --port "$PORT"