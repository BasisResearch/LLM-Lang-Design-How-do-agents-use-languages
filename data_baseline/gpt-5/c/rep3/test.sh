#!/usr/bin/env bash
set -euo pipefail
unset BASH_ENV ENV || true
PORT=18080

# Ensure jq and curl
if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y jq
fi

./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

# Wait for server
for i in {1..50}; do
  if curl -sS "http://127.0.0.1:$PORT/me" -o /dev/null -w '' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "Testing register..."
RES=$(curl -sS -D /tmp/h1 -o /tmp/b1 -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
CODE=$(grep -m1 HTTP/ /tmp/h1 | awk '{print $2}')
[ "$CODE" = "201" ]
[ "$(jq -r '.username' /tmp/b1)" = "alice" ]
grep -qi 'Content-Type: application/json' /tmp/h1

# Duplicate username
curl -sS -D /tmp/h2 -o /tmp/b2 -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h2 | awk '{print $2}')
[ "$CODE" = "409" ]

# Bad login
curl -sS -D /tmp/h3 -o /tmp/b3 -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"wrong"}' >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h3 | awk '{print $2}')
[ "$CODE" = "401" ]

# Good login
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h4 -o /tmp/b4 -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' >/dev/null
CODE=$(grep -m1 HTTP/ /tmp/h4 | awk '{print $2}')
[ "$CODE" = "200" ]
[ -s /tmp/alice_cj ]

# /me
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h5 -o /tmp/b5 "http://127.0.0.1:$PORT/me" >/dev/null
CODE=$(grep -m1 HTTP/ /tmp/h5 | awk '{print $2}')
[ "$CODE" = "200" ]
[ "$(jq -r '.username' /tmp/b5)" = "alice" ]

# password change invalid
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h6 -o /tmp/b6 -X PUT "http://127.0.0.1:$PORT/password" -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword"}' >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h6 | awk '{print $2}')
[ "$CODE" = "401" ]

# password change valid
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h7 -o /tmp/b7 -X PUT "http://127.0.0.1:$PORT/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword"}' >/dev/null
CODE=$(grep -m1 HTTP/ /tmp/h7 | awk '{print $2}')
[ "$CODE" = "200" ]

# Create todo without title -> 400
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h8 -o /tmp/b8 -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' -d '{"description":"x"}' >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h8 | awk '{print $2}')
[ "$CODE" = "400" ]

# Create todo
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h9 -o /tmp/b9 -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' -d '{"title":"Task1","description":"Desc1"}' >/dev/null
CODE=$(grep -m1 HTTP/ /tmp/h9 | awk '{print $2}')
[ "$CODE" = "201" ]
ALICE_TODO_ID=$(jq -r '.id' /tmp/b9)

# Register and login bob
curl -sS -D /tmp/h10 -o /tmp/b10 -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"bob","password":"password456"}' >/dev/null
curl -sS -c /tmp/bob_cj -b /tmp/bob_cj -D /tmp/h11 -o /tmp/b11 -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' -d '{"username":"bob","password":"password456"}' >/dev/null

# Bob cannot access Alice's todo
curl -sS -c /tmp/bob_cj -b /tmp/bob_cj -D /tmp/h12 -o /tmp/b12 "http://127.0.0.1:$PORT/todos/$ALICE_TODO_ID" >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h12 | awk '{print $2}')
[ "$CODE" = "404" ]

# Bob creates his todo
curl -sS -c /tmp/bob_cj -b /tmp/bob_cj -D /tmp/h13 -o /tmp/b13 -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' -d '{"title":"BobTask","description":"B"}' >/dev/null
BOB_TODO_ID=$(jq -r '.id' /tmp/b13)

# Alice cannot access Bob's todo
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h14 -o /tmp/b14 "http://127.0.0.1:$PORT/todos/$BOB_TODO_ID" >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h14 | awk '{print $2}')
[ "$CODE" = "404" ]

# List Alice todos
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h15 -o /tmp/b15 "http://127.0.0.1:$PORT/todos" >/dev/null
[ "$(jq 'length' /tmp/b15)" = "1" ]

# Update Alice todo
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h16 -o /tmp/b16 -X PUT "http://127.0.0.1:$PORT/todos/$ALICE_TODO_ID" -H 'Content-Type: application/json' -d '{"completed":true}' >/dev/null
CODE=$(grep -m1 HTTP/ /tmp/h16 | awk '{print $2}')
[ "$CODE" = "200" ]
[ "$(jq -r '.completed' /tmp/b16)" = "true" ]

# Update with empty title -> 400
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h17 -o /tmp/b17 -X PUT "http://127.0.0.1:$PORT/todos/$ALICE_TODO_ID" -H 'Content-Type: application/json' -d '{"title":""}' >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h17 | awk '{print $2}')
[ "$CODE" = "400" ]

# Delete Alice todo
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h18 -o /tmp/b18 -X DELETE "http://127.0.0.1:$PORT/todos/$ALICE_TODO_ID" >/dev/null
CODE=$(grep -m1 HTTP/ /tmp/h18 | awk '{print $2}')
[ "$CODE" = "204" ]
! grep -qi 'Content-Type:' /tmp/h18 || (echo 'DELETE should not have Content-Type' && false)

# Ensure deleted
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h19 -o /tmp/b19 "http://127.0.0.1:$PORT/todos/$ALICE_TODO_ID" >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h19 | awk '{print $2}')
[ "$CODE" = "404" ]

# Logout Alice
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h20 -o /tmp/b20 -X POST "http://127.0.0.1:$PORT/logout" >/dev/null
CODE=$(grep -m1 HTTP/ /tmp/h20 | awk '{print $2}')
[ "$CODE" = "200" ]

# Access after logout must be 401
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h21 -o /tmp/b21 "http://127.0.0.1:$PORT/me" >/dev/null || true
CODE=$(grep -m1 HTTP/ /tmp/h21 | awk '{print $2}')
[ "$CODE" = "401" ]

# Login with new password
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h22 -o /tmp/b22 -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"newpassword"}' >/dev/null
CODE=$(grep -m1 HTTP/ /tmp/h22 | awk '{print $2}')
[ "$CODE" = "200" ]

# Final check content-type on success
curl -sS -c /tmp/alice_cj -b /tmp/alice_cj -D /tmp/h23 -o /tmp/b23 "http://127.0.0.1:$PORT/todos" >/dev/null
grep -qi 'Content-Type: application/json' /tmp/h23

echo "All tests passed"
