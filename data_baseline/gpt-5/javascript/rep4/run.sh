#!/bin/sh
PORT=3000
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      shift
      PORT="$1"
      ;;
  esac
  shift
done
exec node server.js --port "$PORT"
