#!/usr/bin/env bash
set -euo pipefail
PORT=8080
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      if [[ -n "${2-}" ]]; then PORT="$2"; shift 2; else echo "--port requires an argument" >&2; exit 1; fi;;
    *) echo "Unknown argument: $1" >&2; exit 1;;
  esac
done
cd "$(dirname "$0")/todo_server"
cargo build --release
exec target/release/todo_server --port "$PORT"
