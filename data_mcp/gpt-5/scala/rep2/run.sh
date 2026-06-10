#!/usr/bin/env bash
set -euo pipefail

PORT=8080

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port|-p)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Prefer local scala-cli binary in project root to avoid modifying profiles
SCALA_CLI_BIN="$(pwd)/scala-cli"
if [[ ! -x "$SCALA_CLI_BIN" ]]; then
  if command -v scala-cli >/dev/null 2>&1; then
    SCALA_CLI_BIN="$(command -v scala-cli)"
  else
    echo "Downloading scala-cli binary..." >&2
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64|amd64) ARCH_TAG=x86_64 ;;
      aarch64|arm64) ARCH_TAG=aarch64 ;;
      *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
    esac
    URL="https://github.com/VirtusLab/scala-cli/releases/latest/download/scala-cli-${ARCH_TAG}-pc-linux.gz"
    curl -sSLf "$URL" -o scala-cli.gz
    gunzip -f scala-cli.gz
    chmod +x scala-cli
    SCALA_CLI_BIN="$(pwd)/scala-cli"
  fi
fi

JAR="todo-server.jar"
# Build fat jar if missing or sources newer than jar
need_build=false
if [[ ! -f "$JAR" ]]; then
  need_build=true
else
  for f in $(find src -type f -name '*.scala'); do
    if [[ "$f" -nt "$JAR" ]]; then need_build=true; break; fi
  done
fi

if $need_build; then
  echo "Packaging server..." >&2
  "$SCALA_CLI_BIN" --power package . -f --assembly -o "$JAR"
fi

exec java -jar "$JAR" --port "$PORT"