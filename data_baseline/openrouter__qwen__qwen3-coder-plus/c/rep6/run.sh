#!/bin/bash

# Parse arguments
PORT=8080
for i in "$@"; do
case $i in
    --port=*)
    PORT="${i#*=}"
    shift
    ;;
    --port)
    PORT="$2"
    shift 2
    ;;
    *)
    # unknown option
    ;;
esac
done

# Install dependencies if they're not already installed
if ! pkg-config --exists libuuid; then
    echo "Installing uuid-dev package..."
    apt-get update > /dev/null 2>&1
    apt-get install -y uuid-dev > /dev/null 2>&1
fi

if ! pkg-config --exists json-c; then
    echo "Installing libjson-c-dev package..."
    apt-get update > /dev/null 2>&1
    apt-get install -y libjson-c-dev > /dev/null 2>&1
fi

# Check if json-c headers are available otherwise install via apt
if [ ! -f /usr/include/json-c/json.h ] && [ ! -f /usr/include/json/json.h ]; then
    echo "Installing libjson-c-dev..."
    apt-get update > /dev/null 2>&1
    apt-get install -y libjson-c-dev > /dev/null 2>&1
fi

# Compile the server
echo "Compiling server..."
gcc -o todo_server todo_server.c -luuid -ljson-c -D_GNU_SOURCE

# Check compiler output
if [ $? -ne 0 ]; then
    echo "Compilation failed!"
    exit 1
else
    echo "Compilation successful!"
fi

# Make sure the binary is executable
chmod +x todo_server

# Run the server with the specified port
echo "Starting server on port $PORT..."
./todo_server --port $PORT