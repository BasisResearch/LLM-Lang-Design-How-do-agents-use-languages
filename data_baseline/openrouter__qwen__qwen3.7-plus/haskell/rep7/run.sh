#!/bin/bash
set -e

PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
        *) shift ;;
    esac
    shift
done

echo "Starting server on port $PORT"
exec cabal run todo-app -- --port "$PORT"
