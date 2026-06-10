#!/bin/bash
set -euo pipefail
PORT=8080
# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *)
      echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

# Compile sources
mkdir -p build
find src -name '*.java' > build/sources.list || true
if [[ ! -s build/sources.list ]]; then
  echo "No Java sources found" >&2
  exit 1
fi
javac -d build @build/sources.list

# Run server
exec java -cp build todo.Server --port "$PORT"