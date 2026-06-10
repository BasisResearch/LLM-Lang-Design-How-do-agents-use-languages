#!/bin/bash
pip install flask > /dev/null 2>&1 || true
exec python3 server.py "$@"