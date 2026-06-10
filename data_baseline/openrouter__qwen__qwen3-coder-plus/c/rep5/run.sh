#!/bin/bash

# Install dependencies
sudo apt-get update
sudo apt-get install -y uuid-dev build-essential

# Compile the server
gcc -o server server.c -luuid -lpthread

# Run the server with passed arguments
./server "$@"