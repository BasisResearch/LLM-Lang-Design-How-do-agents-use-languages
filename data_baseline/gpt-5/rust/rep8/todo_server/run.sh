#!/usr/bin/env bash
set -euo pipefail
PORT=8080
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      shift
      PORT=${1:-8080}
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done
# Build and run
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
cargo build --release
exec target/release/todo_server --port "$PORT"
