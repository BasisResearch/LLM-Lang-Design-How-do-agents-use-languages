#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
cargo build --release
exec ./target/release/todo_server --port "$PORT"
