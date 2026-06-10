#!/bin/bash
set -e

# Compile the Java file
javac TodoServer.java

# Extract port from arguments, default to 8080
PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift 2 ;;
        --port=*) PORT="${1#*=}"; shift 1 ;;
        *) shift 1 ;;
    esac
done

exec java TodoServer --port "$PORT"