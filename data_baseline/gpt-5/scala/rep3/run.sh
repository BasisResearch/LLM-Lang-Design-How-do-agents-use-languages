#!/usr/bin/env bash
set -euo pipefail

PORT=8080

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      shift
      PORT=${1:-8080}
      shift || true
      ;;
    *)
      shift
      ;;
  esac
done

# Ensure scala-cli is installed
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "scala-cli not found, installing..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

# Run the server binding to 0.0.0.0:$PORT
exec scala-cli run . -- --port "$PORT"