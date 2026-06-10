#!/usr/bin/env bash
set -euo pipefail
PORT=3000
if [[ "${1:-}" == "--port" ]]; then
  if [[ -n "${2:-}" ]]; then
    PORT="$2"
  else
    echo "--port requires a value" >&2
    exit 1
  fi
fi

cd todo_server
cargo build --release
exec ./target/release/todo_server --port "$PORT"
