#!/bin/bash
set -e
if [ ! -d "node_modules" ]; then
  npm install
fi
npx tsc
node dist/index.js "$@"
