#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1:-} == "--port" && -n ${2:-} ]]; then
  PORT="$2"
fi
# Ensure scala-cli is installed
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "Installing scala-cli..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y >/dev/null 2>&1 || {
    echo "Failed to install scala-cli" >&2
    exit 1
  }
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi
export PORT
# Run the server binding to 0.0.0.0:PORT
exec scala-cli run . -- --port "$PORT"