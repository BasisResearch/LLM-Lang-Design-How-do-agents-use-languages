#!/bin/bash
set -e

PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

gcc -o server server.c -lmicrohttpd -lcjson -luuid -lpthread
./server --port "$PORT"