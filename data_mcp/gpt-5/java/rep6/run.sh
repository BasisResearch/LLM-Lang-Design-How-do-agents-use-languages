#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "$#" -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
mkdir -p out
javac -d out src/Main.java
exec java -cp out Main --port "$PORT"
