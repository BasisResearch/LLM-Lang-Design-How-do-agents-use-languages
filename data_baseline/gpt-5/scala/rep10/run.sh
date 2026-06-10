#!/usr/bin/env bash
set -euo pipefail

# Ensure scala-cli is installed
if ! command -v scala-cli &> /dev/null; then
  echo "scala-cli not found, installing..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y >/dev/null 2>&1 || {
    echo "Failed to install scala-cli" >&2
    exit 1
  }
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

PORT=8080

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

export APP_PORT="$PORT"

# Run the server binding to 0.0.0.0:PORT
exec scala-cli run src -- --port "$PORT"