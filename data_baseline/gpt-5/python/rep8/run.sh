#!/bin/bash
set -euo pipefail
PORT=8000

# Parse arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --port)
      PORT="$2"
      shift
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Ensure dependencies
if ! python3 -c "import flask" >/dev/null 2>&1; then
  pip3 install --no-cache-dir flask >/dev/null
fi

exec python3 app.py --port "$PORT"
