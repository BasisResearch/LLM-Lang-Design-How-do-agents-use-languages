#!/usr/bin/env bash
set -euo pipefail
PORT=8080
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"; shift 2;;
    *) echo "Unknown argument: $1"; exit 1;;
  esac
done

mkdir -p lib out
GSON_JAR="lib/gson-2.10.1.jar"
if [[ ! -f "$GSON_JAR" ]]; then
  echo "Downloading Gson library..."
  URL="https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$GSON_JAR"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$URL" -O "$GSON_JAR"
  else
    echo "Error: curl or wget is required to download dependencies" >&2
    exit 1
  fi
fi

# Compile if needed or if source is newer
if [[ ! -f out/Main.class || Main.java -nt out/Main.class ]]; then
  echo "Compiling..."
  javac -cp "$GSON_JAR" -d out Main.java
fi

exec java -cp "out:$GSON_JAR" Main --port "$PORT"
