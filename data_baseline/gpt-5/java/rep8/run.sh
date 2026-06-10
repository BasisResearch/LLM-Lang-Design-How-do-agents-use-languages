#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1-} == "--port" ]]; then
  PORT=${2-8080}
elif [[ ${2-} == "--port" ]]; then
  PORT=${3-8080}
fi
# Prepare lib dir and fetch gson if missing
LIB_DIR="lib"
GSON_JAR="$LIB_DIR/gson-2.10.1.jar"
mkdir -p "$LIB_DIR"
if [[ ! -f "$GSON_JAR" ]]; then
  echo "Downloading Gson library..."
  curl -L -o "$GSON_JAR" https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
fi
# Compile
javac -cp "$GSON_JAR" Main.java
# Run
exec java -cp ".:$GSON_JAR" Main --port "$PORT"
