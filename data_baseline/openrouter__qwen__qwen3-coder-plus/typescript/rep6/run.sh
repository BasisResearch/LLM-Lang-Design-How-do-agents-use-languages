#!/bin/bash

# Parse arguments
PORT=3000
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift # past argument
      shift # past value
      ;;
    *)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

# Install dependencies first
npm install

# Run directly with tsx since we're using TypeScript without compilation step for simplicity
npx tsx server.ts --port $PORT