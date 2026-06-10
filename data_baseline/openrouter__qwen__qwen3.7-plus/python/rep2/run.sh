#!/bin/bash
pip install flask --break-system-packages -q 2>/dev/null || pip install flask -q
exec python3 server.py "$@"