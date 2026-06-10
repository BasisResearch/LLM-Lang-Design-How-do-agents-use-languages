#!/bin/bash
# Smart wrapper: detects whether run.sh expects --port <N> or just <N>
# Usage: smart_run.sh <path/to/run.sh> --port <PORT>

RUN_SCRIPT="$1"
shift
# Parse --port from remaining args
while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

WORKDIR=$(dirname "$RUN_SCRIPT")
cd "$WORKDIR"

# If run.sh mentions --port anywhere, pass --port flag
if grep -q "\-\-port" "$RUN_SCRIPT" 2>/dev/null; then
    exec bash "$RUN_SCRIPT" --port "$PORT"
else
    exec bash "$RUN_SCRIPT" "$PORT"
fi
