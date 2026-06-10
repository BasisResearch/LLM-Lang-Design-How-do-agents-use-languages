#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ "${1-}" == "--port" && -n "${2-}" ]]; then
  PORT="$2"
fi
exec scala-cli run -q src/Main.scala -- --port "$PORT"