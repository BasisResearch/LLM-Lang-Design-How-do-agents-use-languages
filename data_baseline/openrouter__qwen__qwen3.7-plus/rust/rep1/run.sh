#!/bin/sh
cargo build --release
./target/release/todo_api "$@"
