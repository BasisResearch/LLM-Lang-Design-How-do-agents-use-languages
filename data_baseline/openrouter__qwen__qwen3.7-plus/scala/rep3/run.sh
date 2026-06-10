#!/bin/bash
set -e

if ! command -v scala-cli &> /dev/null; then
    echo "Installing scala-cli..."
    curl -sSLf https://scala-cli.virtuslab.org/get | bash
    export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

scala-cli run Server.scala -- "$@"