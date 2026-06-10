#!/usr/bin/env bash
set -euo pipefail

PORT=8000

# Parse --port argument
while [[ $# -gt 0 ]]; do
  case $1 in
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

# Setup virtual environment locally to install dependencies without system-wide changes
VENV_DIR=".venv"
PYTHON_BIN="python3"

if [[ ! -d "$VENV_DIR" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

# Install Flask if not present
python - <<'PY'
import importlib, sys, subprocess
try:
    importlib.import_module('flask')
except Exception:
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--quiet', 'flask'])
PY

exec python server.py --port "$PORT"