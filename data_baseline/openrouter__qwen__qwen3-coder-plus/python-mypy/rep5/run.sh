#!/bin/bash

PYTHON_PATH=$(which python3)
if [ ! -f "$PYTHON_PATH" ]; then
    echo "python3 not found"
    exit 1
fi

"$PYTHON_PATH" -u server.py "$@"