#!/bin/bash
PORT=8080
if [[ "$1" == "--port" && "$2" =~ ^[0-9]+$ ]]; then
  PORT=$2
fi

# Install scala-cli if not present
if ! command -v scala-cli &> /dev/null; then
  export COURSIER_INSTALL_DIR="$HOME/.local/share/coursier/bin"
  mkdir -p "$COURSIER_INSTALL_DIR"
  curl -sSLf https://scala-cli.virtuslab.org/get | bash
  export PATH="$COURSIER_INSTALL_DIR:$PATH"
fi

scala-cli run Server.scala -- "$PORT"