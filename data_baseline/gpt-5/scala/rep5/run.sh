#!/usr/bin/env bash
set -euo pipefail

PORT=8080
if [[ ${1-} == "--port" ]]; then
  PORT=${2-8080}
fi

# Install scala-cli if not present
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "scala-cli not found, installing..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y >/dev/null 2>&1 || {
    echo "Failed to install scala-cli" >&2
    exit 1
  }
  # Add common install locations to PATH
  export PATH="$HOME/.local/share/coursier/bin:$HOME/bin:$PATH"
fi

# Run the server binding to 0.0.0.0:$PORT
exec scala-cli run . -- --port "$PORT"