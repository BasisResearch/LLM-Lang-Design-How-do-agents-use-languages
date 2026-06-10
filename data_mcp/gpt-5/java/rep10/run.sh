#!/usr/bin/env bash
set -euo pipefail

PORT=8080

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Ensure gson jar exists
LIB_DIR="lib"
GSON_JAR="$LIB_DIR/gson-2.10.1.jar"
if [[ ! -f "$GSON_JAR" ]]; then
  mkdir -p "$LIB_DIR"
  echo "Downloading Gson library..." >&2
  curl -L -o "$GSON_JAR" https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
fi

# Compile
SRC_DIR="src"
BIN_DIR="bin"
mkdir -p "$BIN_DIR"
find "$BIN_DIR" -type f -name '*.class' -delete || true

javac -cp "$GSON_JAR" -d "$BIN_DIR" $(find "$SRC_DIR" -type f -name '*.java')

# Run
exec java -cp "$BIN_DIR:$GSON_JAR" ServerMain --port "$PORT"
