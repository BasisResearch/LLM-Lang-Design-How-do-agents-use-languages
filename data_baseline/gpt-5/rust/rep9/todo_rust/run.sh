#!/usr/bin/env bash
set -euo pipefail
PORT=8080
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done
cd "$(dirname "$0")"
cargo build --release
exec target/release/todo_server --port "$PORT"
