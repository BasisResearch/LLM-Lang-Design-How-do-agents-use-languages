#!/bin/sh
# Start the Node.js server
# Usage: ./run.sh --port PORT

PORT=3000

# Parse args
while [ "$1" != "" ]; do
  case $1 in
    --port)
      shift
      PORT=$1
      ;;
  esac
  shift
done

exec node server.js --port "$PORT"
