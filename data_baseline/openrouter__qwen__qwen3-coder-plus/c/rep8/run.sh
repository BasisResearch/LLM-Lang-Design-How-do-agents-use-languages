#!/bin/bash

# Install required dependencies
sudo apt-get update
sudo apt-get install -y uuid-dev build-essential

# Compilation and execution
gcc -o server server.c -luuid
./server "$@"