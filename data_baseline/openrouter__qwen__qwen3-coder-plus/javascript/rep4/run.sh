#!/bin/bash

# Default port
PORT=3000

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

echo "Starting Todo App server on port $PORT"

# Start the server using node
exec node server.js --port "$PORT"