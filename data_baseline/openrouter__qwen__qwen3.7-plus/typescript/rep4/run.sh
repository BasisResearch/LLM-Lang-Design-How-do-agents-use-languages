#!/bin/bash

# run.sh
# Accepts --port PORT to specify the listening port

PORT=3000

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Compile TypeScript
npx tsc || exit 1

# Start server
exec node dist/index.js --port "$PORT"
