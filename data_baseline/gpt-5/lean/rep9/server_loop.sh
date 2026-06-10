#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1:-} == "--port" ]]; then PORT="$2"; fi
IPC_DIR=${IPC_DIR:-./ipc}
rm -rf "$IPC_DIR"
mkdir -p "$IPC_DIR"
mkfifo "$IPC_DIR/queue.fifo"
# Start Lean worker to process requests from FIFO
./build/bin/todo --ipc "$IPC_DIR" &
WORKER_PID=$!
# Start socat TCP server that invokes conn.sh per connection
export IPC_DIR
socat TCP-LISTEN:"$PORT",fork,reuseaddr SYSTEM:"$PWD/conn.sh",stderr=0 &
SOCAT_PID=$!
trap 'kill $SOCAT_PID $WORKER_PID 2>/dev/null || true; wait $SOCAT_PID 2>/dev/null || true; wait $WORKER_PID 2>/dev/null || true' EXIT
wait $SOCAT_PID $WORKER_PID
