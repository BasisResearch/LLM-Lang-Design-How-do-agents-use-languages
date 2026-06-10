#!/bin/bash

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Use default port if none was set
: "${PORT:=3000}"

# Install dependencies (if not already installed)
npm install

# Compile and run the TypeScript application
npx tsx server.ts --port $PORT