#!/bin/sh
set -e
PORT=
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      shift
      PORT="$1"
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done
if [ -z "$PORT" ]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
# Setup virtual environment locally to avoid system package restrictions
VENV_DIR=".venv"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
. "$VENV_DIR/bin/activate"
python - <<'PY'
import importlib, sys, subprocess
try:
    importlib.import_module('flask')
except Exception:
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--no-cache-dir', 'flask'])
PY
exec "$VENV_DIR/bin/python" app.py --port "$PORT"
