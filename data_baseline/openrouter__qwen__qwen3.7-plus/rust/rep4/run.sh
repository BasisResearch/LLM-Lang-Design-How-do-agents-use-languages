#!/bin/bash
set -e
cargo build --release
./target/release/todo_app "$@"