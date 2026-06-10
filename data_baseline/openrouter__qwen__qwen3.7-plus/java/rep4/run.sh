#!/bin/bash
javac Server.java
exec java Server "$@"
