#!/bin/bash
cabal build
exec cabal run todo-app -- "$@"
