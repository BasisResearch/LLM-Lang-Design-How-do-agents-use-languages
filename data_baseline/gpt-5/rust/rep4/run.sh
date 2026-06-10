#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ ${1-} == "--port" && -n ${2-} ]]; then
  PORT=$2
fi
cd todo_server
cargo build --release
exec target/release/todo_server --port "$PORT"
