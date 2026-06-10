#!/bin/bash

# Get port argument
PORT=8080
for i in "$@"; do
  case $i in
    --port)
      PORT="$2"
      shift
      shift
      ;;
    --port=*)
      PORT="${i#*=}"
      shift
      ;;
    *)
      ;;
  esac
done

# Compile mongoose and server.c
gcc -o server server.c mongoose.c -DMG_ENABLE_LINES=1

# Start the server
./server --port $PORT
