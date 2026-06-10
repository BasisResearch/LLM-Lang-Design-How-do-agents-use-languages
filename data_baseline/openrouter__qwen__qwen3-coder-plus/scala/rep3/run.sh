#!/bin/bash

# Extract port argument
PORT=8080

while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Run the Scala server
scala-cli run Main.scala -- --port $PORT