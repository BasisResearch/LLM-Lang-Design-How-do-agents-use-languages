#!/usr/bin/env bash
set -euo pipefail
PORT=8080
# parse --port
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      shift
      PORT="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Build and run
cargo build --manifest-path todo_server/Cargo.toml --release
exec ./todo_server/target/release/todo_server --port "$PORT"