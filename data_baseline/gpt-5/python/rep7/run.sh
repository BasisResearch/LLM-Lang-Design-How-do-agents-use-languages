#!/bin/sh
# Run the Todo App server
PORT=8080
while [ "$1" != "" ]; do
  case $1 in
    --port)
      shift
      PORT="$1"
      ;;
    *)
      echo "Unknown option: $1" 1>&2
      exit 1
      ;;
  esac
  shift
done
exec python3 server.py --port "$PORT"