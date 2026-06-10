#!/bin/bash

PORT=8000

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift # past argument
      shift # past value
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      shift
      ;;
  esac
done

# Compile all Java files
javac *.java

if [ $? -ne 0 ]; then
  echo "Compilation failed!"
  exit 1
fi

echo "Starting server on port $PORT..."
java TodoServer --port $PORT