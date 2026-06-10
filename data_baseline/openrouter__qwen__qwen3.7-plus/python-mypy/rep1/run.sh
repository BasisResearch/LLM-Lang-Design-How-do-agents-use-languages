#!/bin/bash
set -e

PORT=8000
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift 2 ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
done

exec uvicorn server:app --host 0.0.0.0 --port "$PORT"
