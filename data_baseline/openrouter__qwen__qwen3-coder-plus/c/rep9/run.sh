#!/bin/bash
set -e

# Install uuid-dev if not present
if ! dpkg -l | grep -q libuuid-dev; then
    sudo apt-get update
    sudo apt-get install -y libuuid-dev
fi

# Compilation step
gcc -o server server.c -luuid

# Run with provided arguments
./server "$@"