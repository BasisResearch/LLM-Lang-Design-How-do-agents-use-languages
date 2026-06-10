#!/bin/bash
set -e

export PATH="$HOME/.local/share/coursier/bin:$HOME/.scala-cli:$PATH"

if ! command -v scala-cli &> /dev/null; then
    echo "Installing scala-cli..."
    curl -sSLf https://scala-cli.virtuslab.org/get | bash
fi

scala-cli run Main.scala -- "$@"