#!/bin/bash
set -e
npx tsc
node dist/server.js "$@"
