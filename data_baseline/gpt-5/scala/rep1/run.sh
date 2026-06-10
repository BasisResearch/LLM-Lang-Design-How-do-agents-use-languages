#!/usr/bin/env bash
set -euo pipefail

PORT=8080

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      shift
      if [[ $# -gt 0 ]]; then
        PORT="$1"
        shift
      else
        echo "--port requires an argument" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Ensure scala-cli is installed
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "scala-cli not found. Installing..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

# Run the server
exec scala-cli run . -- --port "$PORT"