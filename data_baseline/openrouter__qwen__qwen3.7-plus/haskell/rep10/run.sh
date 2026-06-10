#!/bin/bash
set -e
cabal run todo-server -- "$@"
