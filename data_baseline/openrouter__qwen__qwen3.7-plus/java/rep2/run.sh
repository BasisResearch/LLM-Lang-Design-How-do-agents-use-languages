#!/bin/bash
PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

javac Main.java
java -cp . Main --port "$PORT"