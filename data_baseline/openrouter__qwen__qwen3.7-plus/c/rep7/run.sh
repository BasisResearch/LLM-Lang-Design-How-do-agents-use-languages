#!/bin/bash
set -e

# Install dependencies if not present
if ! dpkg -l | grep -q libcjson-dev; then
    apt-get update -qq
    apt-get install -y -qq libcjson-dev
fi

# Compile the server
gcc -O2 -Wall -Wextra -o server server.c -lcjson

# Run the server with passed arguments
exec ./server "$@"
