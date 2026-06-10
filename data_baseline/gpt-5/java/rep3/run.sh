#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [ "$#" -ge 2 ]; then
  if [ "$1" == "--port" ]; then
    PORT="$2"
  else
    echo "Usage: $0 --port PORT" >&2
    exit 1
  fi
fi
mkdir -p out
find src -name "*.java" > sources.list
javac -d out @sources.list
rm -f sources.list
exec java -cp out Main --port "$PORT"
