#!/usr/bin/env bash
set -euo pipefail

PORT=8080
if [[ ${1-} == "--port" && -n ${2-} ]]; then
  PORT=$2
fi

# Ensure scala-cli is available
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "scala-cli not found, installing..."
  # Install scala-cli for the current user
  curl -sSLf https://scala-cli.virtuslab.org/get | bash
  # Try to add common install locations to PATH for this script run
  export PATH="$HOME/.local/share/coursier/bin:$HOME/.local/bin:$HOME/bin:$PATH"
fi

echo "Starting server on 0.0.0.0:${PORT}"
exec scala-cli run . -- --port "$PORT"
