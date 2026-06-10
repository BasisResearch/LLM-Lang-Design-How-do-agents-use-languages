#!/usr/bin/env bash
set -euo pipefail
PORT=8080
# Parse --port PORT
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      shift
      PORT=${1:-8080}
      shift
      ;;
    *)
      shift
      ;;
  esac
done
# Ensure scala-cli is available
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "Installing scala-cli..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y >/dev/null
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi
# In case scala-cli was just installed in this session
export PATH="$HOME/.local/share/coursier/bin:$PATH"
export PORT
exec scala-cli run .