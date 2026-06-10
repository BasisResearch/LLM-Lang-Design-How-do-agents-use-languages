#!/bin/bash

# Install dependencies
sudo apt-get update
sudo apt-get install -y libjson-c-dev uuid-dev build-essential

# Compile the server
gcc -o server server.c -ljson-c -luuid -Wall -Wextra -pedantic

# Run the server with provided arguments
./server "$@"