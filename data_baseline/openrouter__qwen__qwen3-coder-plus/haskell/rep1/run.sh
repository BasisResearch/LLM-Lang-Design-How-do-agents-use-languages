#!/bin/bash

# Parse command line arguments
PORT=3000
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift # past argument
      shift # past value
      ;;
    *)
      shift # past unknown option
      ;;
  esac
done

# Build and run the project
echo "Building server..."
cabal build

if [ $? -eq 0 ]; then
    echo "Server building successfully. Running on port $PORT..."
    cabal run -- --port $PORT
else
    echo "Build failed."
    exit 1
fi