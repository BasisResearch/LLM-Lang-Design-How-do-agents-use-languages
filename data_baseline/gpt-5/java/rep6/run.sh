#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" ]]; then
  PORT="$2"
fi
# Compile
mkdir -p out
javac -d out $(find src -name '*.java')
# Run
exec java -cp out Main --port "$PORT"