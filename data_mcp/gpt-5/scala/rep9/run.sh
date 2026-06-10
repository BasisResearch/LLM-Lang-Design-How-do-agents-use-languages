#!/usr/bin/env bash
# Robust launcher for the Scala HTTP server
# Accepts: --port PORT
unset BASH_ENV 2>/dev/null || true
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Error: --port requires a value" >&2
    exit 1
  fi
  PORT="$2"
fi

# Ensure scala-cli is available
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "Installing scala-cli..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi
export PATH="$HOME/.local/share/coursier/bin:$PATH"
export PORT
exec scala-cli run . --server=false --quiet
