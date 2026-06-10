#!/usr/bin/env bash
set -euo pipefail

PORT=8080
if [[ "${1-}" == "--port" && -n "${2-}" ]]; then
  PORT="$2"
fi

# Ensure scala-cli is installed
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "Installing scala-cli..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y >/dev/null
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

export PATH="$HOME/.local/share/coursier/bin:$PATH"

# Build fat JAR
scala-cli package . -f --assembly -o server.jar >/dev/null 2>&1

# Run
exec java -jar server.jar --port "$PORT"