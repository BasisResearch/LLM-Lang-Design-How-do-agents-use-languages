#!/bin/sh
set -eu
PORT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      shift
      PORT="$1"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done
if [ "$PORT" = "0" ] || [ -z "$PORT" ]; then
  echo "Usage: $0 --port PORT" >&2
  exit 1
fi
# Ensure Flask is installed
python3 - <<'PY'
try:
    import flask  # noqa: F401
except Exception:
    raise SystemExit(1)
else:
    raise SystemExit(0)
PY
if [ "$?" -ne 0 ]; then
  pip3 install --no-cache-dir -q flask
fi
exec python3 app.py --port "$PORT"
