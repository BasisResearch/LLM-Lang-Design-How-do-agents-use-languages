#!/bin/bash

# Parse command line arguments
PORT=8080
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift # past argument
      shift # past value
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Run the application with the specified port
scala-cli Main.scala -- --port $PORT