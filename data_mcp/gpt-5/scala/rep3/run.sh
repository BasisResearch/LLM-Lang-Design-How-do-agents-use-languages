#!/usr/bin/env bash
set -euo pipefail
PORT=8080
while [[ $# -gt 0 ]]; do
  case $1 in
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

# Ensure scala-cli is available
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "scala-cli not found, installing..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash -s -- -y
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

HOST=0.0.0.0
exec scala-cli run . -- --port "$PORT" --host "$HOST"