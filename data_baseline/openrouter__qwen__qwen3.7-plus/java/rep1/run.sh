#!/bin/bash

PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

if [ ! -f gson.jar ]; then
    echo "Downloading Gson..."
    curl -sL -o gson.jar https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
fi

echo "Compiling..."
javac -cp .:gson.jar Server.java

echo "Starting server on port $PORT..."
exec java -cp .:gson.jar Server --port "$PORT"
