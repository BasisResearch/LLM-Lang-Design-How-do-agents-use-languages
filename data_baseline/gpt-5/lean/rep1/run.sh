#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1:-}" == "--port" ]]; then
  PORT="$2"
fi
lake build todo_lean
# Kill existing listener on the same port in case a previous run is active
if command -v ss >/dev/null 2>&1; then
  pid=$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $NF}' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1 || true)
  if [[ -n "${pid:-}" ]]; then
    kill "$pid" || true
    sleep 0.2 || true
  fi
fi
./.lake/build/bin/todo_lean --port "$PORT"
