#!/usr/bin/env bash
set -euo pipefail

PORT=""

usage() {
  echo "Usage: $0 --port PORT" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      if [[ $# -lt 2 ]]; then usage; exit 1; fi
      PORT="$2"; shift 2;;
    *)
      usage; exit 1;;
  esac
done

if [[ -z "${PORT}" ]]; then
  usage; exit 1
fi

mkdir -p out
javac -d out $(find src -name "*.java")

exec java -cp out Main --port "${PORT}"
