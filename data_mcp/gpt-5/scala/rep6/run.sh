#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "$#" -ge 2 && "$1" == "--port" ]]; then
  PORT="$2"
fi
# Ensure scala-cli is available
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "scala-cli not found, installing..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi
exec scala-cli run . --server=false -- -Dhttp.port="$PORT" --port "$PORT"