#!/bin/bash

# Parse command line arguments
PORT=8080

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option $1"
            exit 1
            ;;
    esac
done

# Run the Scala script with PORT argument passed as first argument to main
scala-cli run . -- $PORT