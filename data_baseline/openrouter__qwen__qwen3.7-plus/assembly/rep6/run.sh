#!/bin/bash
set -e

PORT=8080
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift ;;
    esac
    shift
done

nasm -f elf64 server.asm -o server.o
ld server.o -o server

exec ./server --port "$PORT"