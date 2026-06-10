#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ $# -ge 2 && $1 == "--port" ]]; then
  PORT=$2
fi

# Ensure libs directory
mkdir -p libs build
GSON_JAR="libs/gson-2.10.1.jar"
if [[ ! -f "$GSON_JAR" ]]; then
  echo "Downloading Gson..."
  curl -L -o "$GSON_JAR" https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
fi

# Compile
JAVAC=javac
JAVA=java
SRC_DIR=src
find "$SRC_DIR" -name "*.java" > build/sources.list
$JAVAC -d build -classpath "$GSON_JAR" @build/sources.list

# Run
exec $JAVA -cp "build:$GSON_JAR" Main --port "$PORT"
