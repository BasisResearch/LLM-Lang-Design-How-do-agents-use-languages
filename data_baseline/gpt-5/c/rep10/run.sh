#!/bin/bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" && -n ${2-} ]]; then
  PORT=$2
elif [[ ${1-} != "" ]]; then
  # parse generic --port PORT anywhere
  for ((i=1;i<=$#;i++)); do
    if [[ ${!i} == "--port" ]]; then
      j=$((i+1))
      if [[ $j -le $# ]]; then PORT=${!j}; fi
      break
    fi
  done
fi

if ! command -v gcc >/dev/null 2>&1; then
  echo "Installing build tools and libs..." >&2
  sudo apt-get update && sudo apt-get install -y build-essential libmicrohttpd-dev libjansson-dev
else
  # Ensure libs are present
  if ! pkg-config --exists jansson 2>/dev/null || ! ldconfig -p | grep -q microhttpd; then
    sudo apt-get update && sudo apt-get install -y libmicrohttpd-dev libjansson-dev
  fi
fi

echo "Compiling..."
gcc -O2 -Wall -Wextra -std=c11 -o server server.c -lmicrohttpd -ljansson -lpthread

echo "Starting server on port $PORT"
exec ./server --port "$PORT"
