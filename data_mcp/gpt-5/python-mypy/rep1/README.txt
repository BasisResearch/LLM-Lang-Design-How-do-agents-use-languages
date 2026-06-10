Todo App Server

Usage:
- ./run.sh --port PORT

Requirements:
- Python 3.8+

Notes:
- In-memory storage only. No persistence.
- Implements cookie-based auth with session_id cookie.
- All responses are JSON with Content-Type: application/json, except DELETE which returns 204 with no body.
- mypy --strict passes with zero errors.

Testing:
- ./test.sh
