#!/usr/bin/env bash
set -euo pipefail

PORT=8080

# Simple args parser for --port
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      if [[ -n "${2-}" ]]; then
        PORT="$2"
        shift 2
      else
        echo "Error: --port requires a value" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Build and run the server
if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust cargo is required but not found. Please install Rust toolchain." >&2
  exit 1
fi

cargo build --release
exec ./target/release/todo_server --port "$PORT"
