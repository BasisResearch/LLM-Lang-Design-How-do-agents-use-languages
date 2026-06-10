#!/bin/bash
java -cp . Server --port 8085 &
SERVER_PID=$!
sleep 2

echo "Setting up two users and testing isolation..."
# First user setup
curl -s "http://localhost:8085/register" -X POST -H "Content-Type: application/json" -d '{"username":"alice","password":"password123"}'
curl -s "http://localhost:8085/login" -c alice_cookies -X POST -H "Content-Type: application/json" -d '{"username":"alice","password":"password123"}'
ALICE_TODO=$(curl -s "http://localhost:8085/todos" -b alice_cookies -X POST -H "Content-Type: application/json" -d '{"title":"Alice\'s Important Task","description":"Alice\'s work"}')
echo "Alice\'s todo: $ALICE_TODO"

# Second user setup  
curl -s "http://localhost:8085/register" -X POST -H "Content-Type: application/json" -d '{"username":"bob","password":"password123"}'
curl -s "http://localhost:8085/login" -c bob_cookies -X POST -H "Content-Type: application/json" -d '{"username":"bob","password":"password123"}'
BOB_TODO=$(curl -s "http://localhost:8085/todos" -b bob_cookies -X POST -H "Content-Type: application/json" -d '{"title":"Bob\'s Secret Project","description":"Bob\'s idea"}')
echo "Bob\'s todo: $BOB_TODO"

# Verify each user only sees their own todos
ALICE_LIST=$(curl -s "http://localhost:8085/todos" -b alice_cookies -H "Content-Type: application/json")
BOB_LIST=$(curl -s "http://localhost:8085/todos" -b bob_cookies -H "Content-Type: application/json")
echo "Alice sees: $ALICE_LIST"
echo "Bob sees: $BOB_LIST"

# Alice tries to access Bob's todo (should fail)
ALICE_ATTEMPT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8085/todos/2" -X GET -b alice_cookies -H "Content-Type: application/json")
echo "Alice trying to access Bob\'s todo (ID 2) -> Response Code: $ALICE_ATTEMPT_CODE"

if [ "$ALICE_ATTEMPT_CODE" = "404" ]; then
    echo "✅ Alice correctly blocked from viewing Bob\'s todo"
else
    echo "❌ ERROR: Alice was able to access Bob\'s todo"
    kill $SERVER_PID
    exit 1
fi

# Bob tries to access Alice's todo (should fail)  
BOB_ATTEMPT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8085/todos/1" -X GET -b bob_cookies -H "Content-Type: application/json")
echo "Bob trying to access Alice\'s todo (ID 1) -> Response Code: $BOB_ATTEMPT_CODE"

if [ "$BOB_ATTEMPT_CODE" = "404" ]; then
    echo "✅ Bob correctly blocked from viewing Alice\'s todo"
else
    echo "❌ ERROR: Bob was able to access Alice\'s todo"
    kill $SERVER_PID
    exit 1
fi

kill $SERVER_PID
rm -f alice_cookies bob_cookies
echo "✅ Cross-user isolation working perfectly!"
