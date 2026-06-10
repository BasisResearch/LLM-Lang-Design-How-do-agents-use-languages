#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "Installing scala-cli..."
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi
export PATH="$HOME/.local/share/coursier/bin:$PATH"
exec scala-cli run src/Main.scala -- --port "$PORT"
