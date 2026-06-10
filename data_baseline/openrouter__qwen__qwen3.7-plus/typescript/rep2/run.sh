#!/bin/bash
npm install
npx tsc
exec node dist/index.js "$@"
