const http = require('http');

const PORT = process.argv[2] || 3000;
const BASE_URL = `http://localhost:${PORT}`;

let cookies = '';

function request(method, path, body = null) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, BASE_URL);
    const options = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method: method,
      headers: {
        'Content-Type': 'application/json',
      }
    };
    if (cookies) {
      options.headers['Cookie'] = cookies;
    }

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.headers['set-cookie']) {
          const cookieStr = res.headers['set-cookie'].find(c => c.includes('session_id='));
          if (cookieStr) {
            if (cookieStr.includes('session_id=;')) {
              cookies = '';
            } else {
              cookies = cookieStr.split(';')[0];
            }
          }
        }
        let parsedData = null;
        if (data) {
          try {
            parsedData = JSON.parse(data);
          } catch (e) {
            parsedData = data;
          }
        }
        resolve({ status: res.statusCode, data: parsedData });
      });
    });

    req.on('error', reject);
    if (body !== null) req.write(JSON.stringify(body));
    req.end();
  });
}

async function runTests() {
  let res;

  console.log('Testing POST /register (valid)...');
  res = await request('POST', '/register', { username: 'testuser', password: 'password123' });
  if (res.status !== 201 || res.data.id !== 1 || res.data.username !== 'testuser') throw new Error('Register failed: ' + JSON.stringify(res));

  console.log('Testing POST /register (duplicate)...');
  res = await request('POST', '/register', { username: 'testuser', password: 'password123' });
  if (res.status !== 409 || res.data.error !== 'Username already exists') throw new Error('Register duplicate failed: ' + JSON.stringify(res));

  console.log('Testing POST /register (invalid username)...');
  res = await request('POST', '/register', { username: 'ab', password: 'password123' });
  if (res.status !== 400 || res.data.error !== 'Invalid username') throw new Error('Register invalid username failed: ' + JSON.stringify(res));

  console.log('Testing POST /register (short password)...');
  res = await request('POST', '/register', { username: 'user2', password: 'short' });
  if (res.status !== 400 || res.data.error !== 'Password too short') throw new Error('Register short password failed: ' + JSON.stringify(res));

  console.log('Testing POST /login (valid)...');
  res = await request('POST', '/login', { username: 'testuser', password: 'password123' });
  if (res.status !== 200 || res.data.id !== 1) throw new Error('Login failed: ' + JSON.stringify(res));
  if (!cookies.includes('session_id=')) throw new Error('Session cookie not set');

  console.log('Testing POST /login (invalid)...');
  res = await request('POST', '/login', { username: 'testuser', password: 'wrongpass' });
  if (res.status !== 401 || res.data.error !== 'Invalid credentials') throw new Error('Login invalid failed: ' + JSON.stringify(res));

  console.log('Testing GET /me...');
  res = await request('GET', '/me');
  if (res.status !== 200 || res.data.username !== 'testuser') throw new Error('Me failed: ' + JSON.stringify(res));

  console.log('Testing PUT /password...');
  res = await request('PUT', '/password', { old_password: 'password123', new_password: 'newpass123' });
  if (res.status !== 200) throw new Error('Change password failed: ' + JSON.stringify(res));

  console.log('Testing PUT /password (wrong old)...');
  res = await request('PUT', '/password', { old_password: 'wrong', new_password: 'newpass123' });
  if (res.status !== 401 || res.data.error !== 'Invalid credentials') throw new Error('Change password wrong old failed: ' + JSON.stringify(res));

  console.log('Testing POST /logout...');
  res = await request('POST', '/logout', {});
  if (res.status !== 200) throw new Error('Logout failed: ' + JSON.stringify(res));

  console.log('Testing GET /me (after logout)...');
  res = await request('GET', '/me');
  if (res.status !== 401 || res.data.error !== 'Authentication required') throw new Error('Auth required failed: ' + JSON.stringify(res));

  console.log('Testing POST /login (for todos)...');
  res = await request('POST', '/login', { username: 'testuser', password: 'newpass123' });
  if (res.status !== 200) throw new Error('Re-login failed: ' + JSON.stringify(res));

  console.log('Testing POST /todos...');
  res = await request('POST', '/todos', { title: 'Buy milk', description: 'From the store' });
  if (res.status !== 201 || res.data.title !== 'Buy milk' || res.data.completed !== false) throw new Error('Create todo failed: ' + JSON.stringify(res));
  const todoId = res.data.id;

  console.log('Testing POST /todos (no title)...');
  res = await request('POST', '/todos', { description: 'No title' });
  if (res.status !== 400 || res.data.error !== 'Title is required') throw new Error('Create todo no title failed: ' + JSON.stringify(res));

  console.log('Testing POST /todos (empty title)...');
  res = await request('POST', '/todos', { title: '' });
  if (res.status !== 400 || res.data.error !== 'Title is required') throw new Error('Create todo empty title failed: ' + JSON.stringify(res));

  console.log('Testing GET /todos...');
  res = await request('GET', '/todos');
  if (res.status !== 200 || !Array.isArray(res.data) || res.data.length !== 1) throw new Error('Get todos failed: ' + JSON.stringify(res));

  console.log('Testing GET /todos/:id...');
  res = await request('GET', `/todos/${todoId}`);
  if (res.status !== 200 || res.data.id !== todoId) throw new Error('Get todo by id failed: ' + JSON.stringify(res));

  console.log('Testing GET /todos/:id (not found)...');
  res = await request('GET', '/todos/999');
  if (res.status !== 404 || res.data.error !== 'Todo not found') throw new Error('Get todo not found failed: ' + JSON.stringify(res));

  console.log('Testing PUT /todos/:id...');
  res = await request('PUT', `/todos/${todoId}`, { title: 'Buy milk and eggs', completed: true });
  if (res.status !== 200 || res.data.title !== 'Buy milk and eggs' || res.data.completed !== true) throw new Error('Update todo failed: ' + JSON.stringify(res));

  console.log('Testing PUT /todos/:id (empty title)...');
  res = await request('PUT', `/todos/${todoId}`, { title: '' });
  if (res.status !== 400 || res.data.error !== 'Title is required') throw new Error('Update todo empty title failed: ' + JSON.stringify(res));

  console.log('Testing DELETE /todos/:id...');
  res = await request('DELETE', `/todos/${todoId}`);
  if (res.status !== 204) throw new Error('Delete todo failed: ' + JSON.stringify(res));

  console.log('Testing DELETE /todos/:id (not found)...');
  res = await request('DELETE', `/todos/${todoId}`);
  if (res.status !== 404 || res.data.error !== 'Todo not found') throw new Error('Delete todo not found failed: ' + JSON.stringify(res));

  // Test cross-user todo access
  console.log('Testing POST /register (user2)...');
  res = await request('POST', '/register', { username: 'user2', password: 'password123' });
  if (res.status !== 201) throw new Error('Register user2 failed');

  console.log('Testing POST /login (user2)...');
  res = await request('POST', '/login', { username: 'user2', password: 'password123' });
  if (res.status !== 200) throw new Error('Login user2 failed');

  // Create a todo for user2
  res = await request('POST', '/todos', { title: 'User 2 Todo' });
  if (res.status !== 201) throw new Error('Create user2 todo failed');
  const user2TodoId = res.data.id;

  // Try to access user2's todo via original user (who we need to log in as)
  console.log('Testing POST /login (testuser)...');
  res = await request('POST', '/login', { username: 'testuser', password: 'newpass123' });
  
  console.log('Testing GET /todos/:id (other user, should be 404)...');
  res = await request('GET', `/todos/${user2TodoId}`);
  if (res.status !== 404 || res.data.error !== 'Todo not found') throw new Error('Cross-user get todo failed: ' + JSON.stringify(res));

  console.log('Testing PUT /todos/:id (other user, should be 404)...');
  res = await request('PUT', `/todos/${user2TodoId}`, { title: 'Hacked' });
  if (res.status !== 404 || res.data.error !== 'Todo not found') throw new Error('Cross-user put todo failed: ' + JSON.stringify(res));

  console.log('Testing DELETE /todos/:id (other user, should be 404)...');
  res = await request('DELETE', `/todos/${user2TodoId}`);
  if (res.status !== 404 || res.data.error !== 'Todo not found') throw new Error('Cross-user delete todo failed: ' + JSON.stringify(res));

  console.log('All tests passed!');
}

runTests().catch(err => {
  console.error('Test failed:', err.message);
  process.exit(1);
});
