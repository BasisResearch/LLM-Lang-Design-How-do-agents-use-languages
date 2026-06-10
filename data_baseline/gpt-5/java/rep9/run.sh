#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ $# -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
# Compile
mkdir -p build
javac -d build src/Server.java
# Run
exec java -cp build Server --port "$PORT"