#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" && -n ${2-} ]]; then
  PORT="$2"
fi
# Install scala-cli if not present
if ! command -v scala-cli >/dev/null 2>&1; then
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi
export PATH="$HOME/.local/share/coursier/bin:$PATH"
exec scala-cli run . -- --port "$PORT"