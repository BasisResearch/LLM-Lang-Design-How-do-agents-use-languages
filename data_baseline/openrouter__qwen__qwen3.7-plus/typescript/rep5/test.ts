const PORT = process.env.PORT || 3000;
const BASE_URL = `http://localhost:${PORT}`;

async function run() {
  console.log("Starting tests on port", PORT);

  // Test 1: Register user
  console.log("Test 1: Register user");
  let res = await fetch(`${BASE_URL}/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'testuser', password: 'password123' })
  });
  let body = await res.json();
  if (res.status !== 201 || !body.id || body.username !== 'testuser') {
    throw new Error(`Test 1 failed: ${res.status} ${JSON.stringify(body)}`);
  }
  console.log("PASS");

  // Test 2: Register existing user
  console.log("Test 2: Register existing user");
  res = await fetch(`${BASE_URL}/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'testuser', password: 'password123' })
  });
  if (res.status !== 409) throw new Error(`Test 2 failed: ${res.status}`);
  console.log("PASS");

  // Test 3: Register with invalid username (too short)
  console.log("Test 3: Register with invalid username (too short)");
  res = await fetch(`${BASE_URL}/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'ab', password: 'password123' })
  });
  if (res.status !== 400) throw new Error(`Test 3 failed: ${res.status}`);
  console.log("PASS");

  // Test 4: Register with invalid username (special chars)
  console.log("Test 4: Register with invalid username (special chars)");
  res = await fetch(`${BASE_URL}/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'test-user', password: 'password123' })
  });
  if (res.status !== 400) throw new Error(`Test 4 failed: ${res.status}`);
  console.log("PASS");

  // Test 5: Register with short password
  console.log("Test 5: Register with short password");
  res = await fetch(`${BASE_URL}/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'testuser3', password: 'short' })
  });
  if (res.status !== 400) throw new Error(`Test 5 failed: ${res.status}`);
  console.log("PASS");

  // Test 6: Login
  console.log("Test 6: Login");
  res = await fetch(`${BASE_URL}/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'testuser', password: 'password123' })
  });
  body = await res.json();
  if (res.status !== 200 || body.username !== 'testuser') throw new Error(`Test 6 failed: ${res.status} ${JSON.stringify(body)}`);
  
  let setCookieHeader = res.headers.get('set-cookie');
  let sessionId = '';
  if (setCookieHeader && setCookieHeader.includes('session_id=')) {
    let match = setCookieHeader.match(/session_id=([^;]+)/);
    if (match) sessionId = match[1];
  } else {
    throw new Error("Test 6 failed: No session_id cookie set");
  }
  console.log("PASS");

  const authHeaders = { 'Content-Type': 'application/json', 'Cookie': `session_id=${sessionId}` };

  // Test 7: GET /me
  console.log("Test 7: GET /me");
  res = await fetch(`${BASE_URL}/me`, { method: 'GET', headers: authHeaders });
  body = await res.json();
  if (res.status !== 200 || body.username !== 'testuser') throw new Error(`Test 7 failed: ${res.status} ${JSON.stringify(body)}`);
  console.log("PASS");

  // Test 8: PUT /password
  console.log("Test 8: PUT /password");
  res = await fetch(`${BASE_URL}/password`, {
    method: 'PUT',
    headers: authHeaders,
    body: JSON.stringify({ old_password: 'password123', new_password: 'newpassword123' })
  });
  if (res.status !== 200) throw new Error(`Test 8 failed: ${res.status}`);
  console.log("PASS");

  // Test 9: PUT /password with wrong old password
  console.log("Test 9: PUT /password with wrong old password");
  res = await fetch(`${BASE_URL}/password`, {
    method: 'PUT',
    headers: authHeaders,
    body: JSON.stringify({ old_password: 'wrongpassword', new_password: 'newpassword123' })
  });
  if (res.status !== 401) throw new Error(`Test 9 failed: ${res.status}`);
  console.log("PASS");

  // Test 10: PUT /password with short new password
  console.log("Test 10: PUT /password with short new password");
  res = await fetch(`${BASE_URL}/password`, {
    method: 'PUT',
    headers: authHeaders,
    body: JSON.stringify({ old_password: 'newpassword123', new_password: 'short' })
  });
  if (res.status !== 400) throw new Error(`Test 10 failed: ${res.status}`);
  console.log("PASS");

  // Test 11: GET /todos (empty)
  console.log("Test 11: GET /todos (empty)");
  res = await fetch(`${BASE_URL}/todos`, { method: 'GET', headers: authHeaders });
  body = await res.json();
  if (res.status !== 200 || !Array.isArray(body) || body.length !== 0) throw new Error(`Test 11 failed: ${res.status} ${JSON.stringify(body)}`);
  console.log("PASS");

  // Test 12: POST /todos
  console.log("Test 12: POST /todos");
  res = await fetch(`${BASE_URL}/todos`, {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify({ title: 'My first todo', description: 'This is a test' })
  });
  body = await res.json();
  if (res.status !== 201 || body.title !== 'My first todo' || body.completed !== false) {
    throw new Error(`Test 12 failed: ${res.status} ${JSON.stringify(body)}`);
  }
  console.log("PASS");

  // Test 13: POST /todos without title
  console.log("Test 13: POST /todos without title");
  res = await fetch(`${BASE_URL}/todos`, {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify({ description: 'This is a test' })
  });
  if (res.status !== 400) throw new Error(`Test 13 failed: ${res.status}`);
  console.log("PASS");

  // Test 14: POST /todos with empty title
  console.log("Test 14: POST /todos with empty title");
  res = await fetch(`${BASE_URL}/todos`, {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify({ title: '', description: 'This is a test' })
  });
  if (res.status !== 400) throw new Error(`Test 14 failed: ${res.status}`);
  console.log("PASS");

  // Test 15: POST /todos with whitespace-only title
  console.log("Test 15: POST /todos with whitespace-only title");
  res = await fetch(`${BASE_URL}/todos`, {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify({ title: '   ', description: 'This is a test' })
  });
  if (res.status !== 400) throw new Error(`Test 15 failed: ${res.status}`);
  console.log("PASS");

  // Test 16: GET /todos/1
  console.log("Test 16: GET /todos/1");
  res = await fetch(`${BASE_URL}/todos/1`, { method: 'GET', headers: authHeaders });
  body = await res.json();
  if (res.status !== 200 || body.title !== 'My first todo') throw new Error(`Test 16 failed: ${res.status} ${JSON.stringify(body)}`);
  console.log("PASS");

  // Test 17: GET /todos/999 (not found)
  console.log("Test 17: GET /todos/999 (not found)");
  res = await fetch(`${BASE_URL}/todos/999`, { method: 'GET', headers: authHeaders });
  if (res.status !== 404) throw new Error(`Test 17 failed: ${res.status}`);
  console.log("PASS");

  // Test 18: PUT /todos/1
  console.log("Test 18: PUT /todos/1");
  res = await fetch(`${BASE_URL}/todos/1`, {
    method: 'PUT',
    headers: authHeaders,
    body: JSON.stringify({ completed: true, title: 'Updated title' })
  });
  body = await res.json();
  if (res.status !== 200 || body.completed !== true || body.title !== 'Updated title') {
    throw new Error(`Test 18 failed: ${res.status} ${JSON.stringify(body)}`);
  }
  console.log("PASS");

  // Test 19: PUT /todos/1 with empty title
  console.log("Test 19: PUT /todos/1 with empty title");
  res = await fetch(`${BASE_URL}/todos/1`, {
    method: 'PUT',
    headers: authHeaders,
    body: JSON.stringify({ title: '' })
  });
  if (res.status !== 400) throw new Error(`Test 19 failed: ${res.status}`);
  console.log("PASS");

  // Test 20: DELETE /todos/1
  console.log("Test 20: DELETE /todos/1");
  res = await fetch(`${BASE_URL}/todos/1`, { method: 'DELETE', headers: authHeaders });
  if (res.status !== 204) throw new Error(`Test 20 failed: ${res.status}`);
  console.log("PASS");

  // Test 21: DELETE /todos/1 (already deleted)
  console.log("Test 21: DELETE /todos/1 (already deleted)");
  res = await fetch(`${BASE_URL}/todos/1`, { method: 'DELETE', headers: authHeaders });
  if (res.status !== 404) throw new Error(`Test 21 failed: ${res.status}`);
  console.log("PASS");

  // Test 22: POST /logout
  console.log("Test 22: POST /logout");
  res = await fetch(`${BASE_URL}/logout`, { method: 'POST', headers: authHeaders });
  if (res.status !== 200) throw new Error(`Test 22 failed: ${res.status}`);
  console.log("PASS");

  // Test 23: GET /me after logout
  console.log("Test 23: GET /me after logout");
  res = await fetch(`${BASE_URL}/me`, { method: 'GET', headers: authHeaders });
  if (res.status !== 401) throw new Error(`Test 23 failed: ${res.status}`);
  console.log("PASS");

  // Test 24: Access protected endpoint without cookie
  console.log("Test 24: Access protected endpoint without cookie");
  res = await fetch(`${BASE_URL}/me`, { method: 'GET', headers: { 'Content-Type': 'application/json' } });
  if (res.status !== 401) throw new Error(`Test 24 failed: ${res.status}`);
  console.log("PASS");

  console.log("All tests passed!");
}

run().catch(err => {
  console.error(err);
  process.exit(1);
});
