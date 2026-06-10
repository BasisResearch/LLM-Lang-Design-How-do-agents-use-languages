#!/bin/bash
set -e

# Install required dependencies if not present
if ! dpkg -l | grep -q "libcjson-dev"; then
    apt-get update -qq
    apt-get install -y -qq libcjson-dev libssl-dev
fi

# Compile the server
gcc -o server server.c -pthread -lcjson -lssl -lcrypto -O2

# Run the server
./server "$@"
