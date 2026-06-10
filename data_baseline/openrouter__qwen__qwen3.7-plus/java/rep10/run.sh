#!/bin/bash

PORT=8080
if [ "$1" = "--port" ] && [ -n "$2" ]; then
    PORT=$2
fi

if [ ! -f gson.jar ]; then
    echo "Downloading Gson..."
    curl -sL -o gson.jar https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
fi

echo "Compiling Server.java..."
javac -cp gson.jar Server.java

echo "Starting server on port $PORT..."
java -cp .:gson.jar Server --port "$PORT"
