#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" ]]; then
  PORT="$2"
fi
# Compile
mkdir -p build
javac -d build src/*.java
# Run
exec java -cp build TodoServer --port "$PORT"