#!/bin/sh
PORT=3000
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
exec node server.js --port "$PORT"