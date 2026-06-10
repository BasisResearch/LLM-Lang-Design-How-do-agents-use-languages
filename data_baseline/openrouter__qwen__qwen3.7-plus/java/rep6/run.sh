#!/bin/bash
PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

if [ ! -f json.jar ]; then
    curl -sL https://repo1.maven.org/maven2/org/json/json/20231013/json-20231013.jar -o json.jar
fi

javac -cp json.jar Server.java
java -cp .:json.jar Server --port "$PORT"