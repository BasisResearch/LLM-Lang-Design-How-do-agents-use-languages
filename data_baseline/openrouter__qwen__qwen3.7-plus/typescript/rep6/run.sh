#!/bin/bash
PORT=3000
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

exec npx tsx src/index.ts --port "$PORT"
