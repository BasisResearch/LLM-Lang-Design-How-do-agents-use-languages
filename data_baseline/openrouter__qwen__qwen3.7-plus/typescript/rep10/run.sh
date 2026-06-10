#!/bin/bash

PORT=3000
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

npm install > /dev/null 2>&1
npx tsc

exec node dist/server.js --port "$PORT"