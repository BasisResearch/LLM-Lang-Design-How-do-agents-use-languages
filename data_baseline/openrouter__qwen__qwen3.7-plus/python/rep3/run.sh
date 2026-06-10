#!/bin/bash
pip install flask -q
exec python3 server.py "$@"