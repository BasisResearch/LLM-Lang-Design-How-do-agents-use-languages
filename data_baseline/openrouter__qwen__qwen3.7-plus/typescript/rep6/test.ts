import http from 'http';

const PORT = process.env.TEST_PORT || '3456';
const HOST = `http://localhost:${PORT}`;

function request(method: string, path: string, body?: any, cookies: string[] = []): Promise<{ status: number, headers: http.IncomingHttpHeaders, body: any }> {
  return new Promise((resolve, reject) => {
    const url = new URL(path, HOST);
    const options: http.RequestOptions = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method,
      headers: {
        'Content-Type': 'application/json',
        'Cookie': cookies.join('; ')
      }
    };

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        let parsedBody: any = null;
        if (data) {
          try {
            parsedBody = JSON.parse(data);
          } catch (e) {
            parsedBody = data;
          }
        }
        resolve({ status: res.statusCode || 0, headers: res.headers, body: parsedBody });
      });
    });

    req.on('error', reject);
    if (body) {
      req.write(JSON.stringify(body));
    }
    req.end();
  });
}

async function runTests() {
  console.log('Starting tests...');

  // 1. Register
  let res = await request('POST', '/register', { username: 'testuser', password: 'password123' });
  if (res.status !== 201) throw new Error(`Register failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('1. Register: OK');

  // 2. Register duplicate
  res = await request('POST', '/register', { username: 'testuser', password: 'password123' });
  if (res.status !== 409) throw new Error(`Register duplicate failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('2. Register duplicate: OK');

  // 3. Login
  res = await request('POST', '/login', { username: 'testuser', password: 'password123' });
  if (res.status !== 200) throw new Error(`Login failed: ${res.status} ${JSON.stringify(res.body)}`);
  const setCookie = res.headers['set-cookie']?.[0] || '';
  const sessionId = setCookie.match(/session_id=([^;]+)/)?.[1];
  if (!sessionId) throw new Error('No session_id in set-cookie');
  const cookies = [`session_id=${sessionId}`];
  console.log('3. Login: OK');

  // 4. Login invalid
  res = await request('POST', '/login', { username: 'testuser', password: 'wrongpassword' });
  if (res.status !== 401) throw new Error(`Login invalid failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('4. Login invalid: OK');

  // 5. GET /me
  res = await request('GET', '/me', undefined, cookies);
  if (res.status !== 200 || res.body.username !== 'testuser') throw new Error(`GET /me failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('5. GET /me: OK');

  // 6. GET /me unauth
  res = await request('GET', '/me');
  if (res.status !== 401) throw new Error(`GET /me unauth failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('6. GET /me unauth: OK');

  // 7. PUT /password
  res = await request('PUT', '/password', { old_password: 'password123', new_password: 'newpassword123' }, cookies);
  if (res.status !== 200) throw new Error(`PUT /password failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('7. PUT /password: OK');

  // 8. PUT /password wrong old
  res = await request('PUT', '/password', { old_password: 'wrongpassword', new_password: 'newpassword123' }, cookies);
  if (res.status !== 401) throw new Error(`PUT /password wrong old failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('8. PUT /password wrong old: OK');

  // 9. POST /todos
  res = await request('POST', '/todos', { title: 'First Todo', description: 'Do this' }, cookies);
  if (res.status !== 201) throw new Error(`POST /todos failed: ${res.status} ${JSON.stringify(res.body)}`);
  const todoId = res.body.id;
  console.log(`9. POST /todos: OK (ID: ${todoId})`);

  // 10. POST /todos empty title
  res = await request('POST', '/todos', { title: '', description: 'Do this' }, cookies);
  if (res.status !== 400) throw new Error(`POST /todos empty title failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('10. POST /todos empty title: OK');

  // 11. GET /todos
  res = await request('GET', '/todos', undefined, cookies);
  if (res.status !== 200 || !Array.isArray(res.body) || res.body.length !== 1) throw new Error(`GET /todos failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('11. GET /todos: OK');

  // 12. GET /todos/:id
  res = await request('GET', `/todos/${todoId}`, undefined, cookies);
  if (res.status !== 200 || res.body.id !== todoId) throw new Error(`GET /todos/:id failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('12. GET /todos/:id: OK');

  // 13. PUT /todos/:id
  res = await request('PUT', `/todos/${todoId}`, { completed: true }, cookies);
  if (res.status !== 200 || res.body.completed !== true) throw new Error(`PUT /todos/:id failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('13. PUT /todos/:id: OK');

  // 14. PUT /todos/:id empty title
  res = await request('PUT', `/todos/${todoId}`, { title: '' }, cookies);
  if (res.status !== 400) throw new Error(`PUT /todos/:id empty title failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('14. PUT /todos/:id empty title: OK');

  // 15. DELETE /todos/:id
  res = await request('DELETE', `/todos/${todoId}`, undefined, cookies);
  if (res.status !== 204) throw new Error(`DELETE /todos/:id failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('15. DELETE /todos/:id: OK');

  // 16. DELETE /todos/:id again
  res = await request('DELETE', `/todos/${todoId}`, undefined, cookies);
  if (res.status !== 404) throw new Error(`DELETE /todos/:id again failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('16. DELETE /todos/:id again: OK');

  // 17. POST /logout
  res = await request('POST', '/logout', undefined, cookies);
  if (res.status !== 200) throw new Error(`POST /logout failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('17. POST /logout: OK');

  // 18. GET /me after logout
  res = await request('GET', '/me', undefined, cookies);
  if (res.status !== 401) throw new Error(`GET /me after logout failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('18. GET /me after logout: OK');

  // 19. ID enumeration protection
  await request('POST', '/register', { username: 'user2', password: 'password123' });
  const res2 = await request('POST', '/login', { username: 'user2', password: 'password123' });
  const sessionId2 = res2.headers['set-cookie']?.[0]?.match(/session_id=([^;]+)/)?.[1];
  const cookies2 = [`session_id=${sessionId2}`];
  
  const res3 = await request('POST', '/todos', { title: 'User2 Todo' }, cookies2);
  const user2TodoId = res3.body.id;

  // Login user1 again to get fresh cookies
  const res4 = await request('POST', '/login', { username: 'testuser', password: 'newpassword123' });
  const sessionId1 = res4.headers['set-cookie']?.[0]?.match(/session_id=([^;]+)/)?.[1];
  const cookies1 = [`session_id=${sessionId1}`];

  res = await request('GET', `/todos/${user2TodoId}`, undefined, cookies1);
  if (res.status !== 404) throw new Error(`ID enumeration protection failed: ${res.status} ${JSON.stringify(res.body)}`);
  console.log('19. ID enumeration protection: OK');

  console.log('All tests passed!');
}

runTests().catch(err => {
  console.error('Test failed:', err);
  process.exit(1);
});
