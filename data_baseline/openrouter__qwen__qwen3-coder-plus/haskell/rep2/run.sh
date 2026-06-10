#!/bin/bash

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

# Set default port if none provided
if [ -z "$PORT" ]; then
  echo "Usage: $0 --port PORT"
  exit 1
fi

# Build the executable with cabal
cabal build

# Check if build was successful
if [ $? -ne 0 ]; then
  echo "Build failed!"
  exit 1
fi

# Run the executable with the provided port
cabal run -- --port $PORT