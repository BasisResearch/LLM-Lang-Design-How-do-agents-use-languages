#!/bin/bash
PORT=3000
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        --port=*)
            PORT="${1#*=}"
            shift
            ;;
        *)
            shift
            ;;
    esac
done
node dist/server.js --port "$PORT"
