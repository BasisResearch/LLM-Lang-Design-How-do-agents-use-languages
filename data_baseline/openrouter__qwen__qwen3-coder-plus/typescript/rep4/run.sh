#!/bin/bash

# Parse command line arguments
PORT=3000
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift # past argument
            shift # past value
            ;;
        *)
            shift
            ;;
    esac
done

# Install dependencies
npm install

# Start the server
npx tsx server.ts --port "$PORT"