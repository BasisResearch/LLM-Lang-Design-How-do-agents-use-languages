#!/bin/bash
PORT=8000
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done
exec uvicorn server:app --host 0.0.0.0 --port "$PORT"
