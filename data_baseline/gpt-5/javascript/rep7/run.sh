#!/bin/sh
# Start the Node.js server, accepting --port PORT
PORT=3000
if [ "$1" = "--port" ] && [ -n "$2" ]; then
  PORT="$2"
fi
exec node server.js --port "$PORT"