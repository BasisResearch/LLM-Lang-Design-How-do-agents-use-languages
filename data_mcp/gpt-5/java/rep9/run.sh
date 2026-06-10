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
      shift
      ;;
  esac
done

# Prepare directories
mkdir -p lib out
GSON_JAR="lib/gson-2.10.1.jar"
if [[ ! -f "$GSON_JAR" ]]; then
  echo "Downloading gson..."
  curl -fsSL -o "$GSON_JAR" https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar
fi

# Compile
if [[ ! -d src ]]; then
  echo "src directory not found" >&2
  exit 1
fi
find src -name '*.java' > sources.list
javac -cp "$GSON_JAR" -d out @sources.list
rm -f sources.list

# Run
exec java -cp "out:$GSON_JAR" Main --port "$PORT"
