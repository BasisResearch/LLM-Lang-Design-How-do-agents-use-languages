#!/bin/bash

# Install scala-cli if not already installed
if ! command -v scala-cli &> /dev/null; then
    echo "Installing scala-cli..."
    curl -sSLf https://scala-cli.virtuslab.org/get | bash
    export PATH="$HOME/.scala-cli/bin:$PATH"
fi

# Use scala-cli to run the server
scala-cli run SimpleTodoService.scala -- "$@"