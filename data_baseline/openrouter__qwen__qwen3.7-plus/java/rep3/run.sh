#!/bin/bash

PORT=8080
ARGS=()
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

javac Main.java
java Main --port "$PORT" "${ARGS[@]}"