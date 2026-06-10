#!/usr/bin/env bash
set -euo pipefail
PORT=8080
if [[ ${1:-} == "--port" ]]; then
  PORT=${2:-8080}
fi
export SCALA_CLI_SUPPRESS_ADRT_WARNING=1
if ! command -v scala-cli >/dev/null 2>&1; then
  echo "Installing scala-cli..." >&2
  curl -sSLf https://scala-cli.virtuslab.org/get | bash
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi
# Run the server binding to 0.0.0.0:PORT
exec scala-cli run Main.scala -- -Djava.net.preferIPv4Stack=true --port "$PORT"
