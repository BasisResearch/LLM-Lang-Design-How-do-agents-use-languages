#!/bin/bash
PORT=8080
for i in "$@"; do
    case $i in
        --port=*)
        PORT="${i#*=}"
        shift
        ;;
        --port)
        PORT="$2"
        shift 2
        ;;
        *)
        ;;
    esac
done
DIR="$(dirname "$(readlink -f "$0")")"
cd "$DIR"
exec ./server --port "$PORT"