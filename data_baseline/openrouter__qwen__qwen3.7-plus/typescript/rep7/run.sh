#!/bin/bash
set -e

PORT=3000
if [ "$1" == "--port" ] && [ -n "$2" ]; then
    PORT="$2"
fi

export PORT
exec npx tsx src/index.ts
