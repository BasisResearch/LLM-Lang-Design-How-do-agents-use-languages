#!/bin/bash
# Setup git to work with HTTPS for public repos without requiring authentication

git config --global url."https://".insteadOf git://
git config --global url."https://github.com/".insteadOf git@github.com:
git config --global url."https://".insteadOf ssh://