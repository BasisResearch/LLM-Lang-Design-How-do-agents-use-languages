#!/bin/bash

# Parse command line options
PORT=8080

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift # past argument
            shift # past value
            ;;
        -*|--*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            shift # past argument
            ;;
    esac
done

# Compile the Java files
javac -d out src/com/todoserver/*.java

if [ $? -ne 0 ]; then
    echo "Compilation failed"
    exit 1
fi

# Run the server
java -cp out com.todoserver.Main --port "$PORT"