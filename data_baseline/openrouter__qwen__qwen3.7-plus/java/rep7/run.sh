#!/bin/bash
PORT=8080
if [ "$1" = "--port" ] && [ -n "$2" ]; then
    PORT=$2
fi

if [ ! -f "gson-2.10.1.jar" ]; then
    echo "Downloading Gson..."
    curl -sL -o gson-2.10.1.jar https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar || wget -q -O gson-2.10.1.jar https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
fi

javac -cp "gson-2.10.1.jar" Server.java
java -cp ".:gson-2.10.1.jar" Server --port "$PORT"