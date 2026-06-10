#!/usr/bin/env bash
set -euo pipefail
PORT=3000
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *)
      shift;;
  esac
done
export RUST_LOG=info
cargo build
exec target/debug/todo_server --port "$PORT"
