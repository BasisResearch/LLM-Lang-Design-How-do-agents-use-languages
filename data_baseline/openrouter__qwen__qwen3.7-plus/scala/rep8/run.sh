#!/bin/bash
# run.sh - Starts the Todo App server

# Find or download scala-cli
if ! command -v scala-cli &> /dev/null; then
    echo "Installing scala-cli..."
    curl -sSLf https://scala-cli.virtuslab.org/get | bash
    export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

# Run the server with the provided port
exec scala-cli run Server.scala -- "$@"