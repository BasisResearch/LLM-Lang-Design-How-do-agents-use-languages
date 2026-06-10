#!/bin/bash
PORT=8080
if [ "$1" == "--port" ] && [ -n "$2" ]; then
    PORT=$2
fi

javac TodoServer.java
java TodoServer --port $PORT