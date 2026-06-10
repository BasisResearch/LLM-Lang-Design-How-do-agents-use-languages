#!/bin/bash
set -e

# Install scala-cli if not present
if ! command -v scala-cli &> /dev/null; then
  echo "Installing scala-cli..."
  curl -sSLf https://scala-cli.virtuslab.org/get | bash
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

PORT=8080
if [[ "$1" == "--port" && -n "$2" ]]; then
  PORT="$2"
fi

scala-cli run Server.scala -- --port "$PORT"