#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ $# -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
# Build the project in the todo_server directory
pushd todo_server >/dev/null
cargo build --release
popd >/dev/null
# Run the server binding to 0.0.0.0:$PORT
exec ./todo_server/target/release/todo_server --port "$PORT"
