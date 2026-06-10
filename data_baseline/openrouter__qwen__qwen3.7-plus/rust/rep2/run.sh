#!/bin/bash
cargo build --release
./target/release/todo_app "$@"
