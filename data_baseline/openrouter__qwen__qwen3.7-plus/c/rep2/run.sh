#!/bin/bash
set -e
PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

gcc -Wall -Wextra -o server server.c -lmicrohttpd -lcjson -luuid -lpthread
if [ $? -ne 0 ]; then
    echo "Compilation failed"
    exit 1
fi

exec ./server --port "$PORT"