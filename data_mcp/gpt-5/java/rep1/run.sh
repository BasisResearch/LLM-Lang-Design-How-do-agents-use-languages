#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" ]]; then
  PORT=${2-8080}
fi
# Ensure lib directory and gson jar
LIBDIR="lib"
JAR="$LIBDIR/gson-2.10.1.jar"
if [[ ! -f "$JAR" ]]; then
  mkdir -p "$LIBDIR"
  URL1="https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar"
  echo "Downloading gson..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL1" -o "$JAR"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$URL1" -O "$JAR"
  else
    echo "Error: curl or wget required to download gson jar" >&2
    exit 1
  fi
fi
# Compile
OUTDIR="out"
mkdir -p "$OUTDIR"
javac -cp "$JAR" -d "$OUTDIR" src/Main.java
# Run
exec java -cp "$OUTDIR:$JAR" Main --port "$PORT"
