#!/bin/bash

# Parse command line arguments
PORT=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift # past argument
      shift # past value
      ;;
    -*)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

if [ "$PORT" -le 0 ]; then
  echo "Usage: $0 --port PORT"
  exit 1
fi

# Compile with gcc including libuuid
gcc -o server server_fixed.c -luuid

if [ $? -ne 0 ]; then
  echo "Compilation failed"
  exit 1
fi

# Run the server
./server --port $PORT