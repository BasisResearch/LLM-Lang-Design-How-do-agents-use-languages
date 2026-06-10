#!/bin/bash
set -e

PORT=8080
if [[ "$1" == "--port" && -n "$2" ]]; then
    PORT=$2
fi

cabal run todo-app -- --port "$PORT"
