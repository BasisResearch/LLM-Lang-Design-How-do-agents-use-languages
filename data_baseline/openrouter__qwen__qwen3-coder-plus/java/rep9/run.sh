#!/bin/bash

# Parse command line arguments
PORT=8080
for i in "$@"; do
    case $i in
        --port=*)
        PORT="${i#*=}"
        shift
        ;;
        --port)
        PORT="$2"
        shift 2
        ;;
        *)
        # unknown option - ignore
        shift
        ;;
    esac
done

# Compile Java source
javac -cp ".:lib/*" -d bin src/com/todo/server/TodoServer.java

# Run the server
java -cp ".:bin:lib/*" com.todo.server.TodoServer --port $PORT