Todo App Server

Usage:
  ./run.sh --port PORT

This starts the Flask-based REST API server bound to 0.0.0.0:PORT.

Development:
  - Python 3 with mypy --strict typing. To check types:
      . venv/bin/activate && mypy --strict app.py
  - Run tests:
      ./test.sh

Endpoints: See problem specification.
