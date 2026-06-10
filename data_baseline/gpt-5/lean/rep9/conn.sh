#!/usr/bin/env bash
set -euo pipefail
IPC_DIR=${IPC_DIR:-./ipc}
mkdir -p "$IPC_DIR"
REQ_FILE=$(mktemp -p "$IPC_DIR" req.XXXXXX)
# Read entire request from stdin into file
cat > "$REQ_FILE"
# Generate id
ID="$(date +%s%N)-$$-$RANDOM"
# Ensure queue fifo exists
if [[ ! -p "$IPC_DIR/queue.fifo" ]]; then
  mkfifo "$IPC_DIR/queue.fifo"
fi
# Send line to queue with id and request file path
# Use exec to open fifo for writing to avoid buffering
{
  printf '%s %s\n' "$ID" "$REQ_FILE"
} > "$IPC_DIR/queue.fifo"
RESP_FILE="$IPC_DIR/resp-$ID.out"
# Wait for response file to appear
for i in $(seq 1 1000); do
  if [[ -f "$RESP_FILE" ]]; then
    break
  fi
  sleep 0.01
done
if [[ ! -f "$RESP_FILE" ]]; then
  # timeout
  echo -ne 'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
  rm -f "$REQ_FILE"
  exit 0
fi
# Output response to client
cat "$RESP_FILE"
# cleanup
rm -f "$REQ_FILE" "$RESP_FILE"
