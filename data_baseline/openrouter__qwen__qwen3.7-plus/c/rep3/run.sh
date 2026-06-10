#!/bin/bash
set -e

# Compile the server
gcc -O2 -Wall -Wno-stringop-truncation -o server server.c -lcjson -luuid -lmicrohttpd -lpthread

# Run the server, passing through any arguments (like --port)
exec ./server "$@"