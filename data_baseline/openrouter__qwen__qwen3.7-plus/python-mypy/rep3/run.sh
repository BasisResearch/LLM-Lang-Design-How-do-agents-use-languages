#!/bin/bash
PORT=8000
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done
. venv/bin/activate
exec uvicorn main:app --host 0.0.0.0 --port "$PORT"
