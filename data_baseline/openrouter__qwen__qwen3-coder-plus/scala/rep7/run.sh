#!/bin/bash
scala-cli run TodoApp.scala -- --port "${@#--port}"