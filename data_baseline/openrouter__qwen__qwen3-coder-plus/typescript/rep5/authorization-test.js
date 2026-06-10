// Test authorization between different users
const http = require('http');
const https = require('https');
const url = require('url');

async function authzTest() {
  console.log("Testing authorization and user isolation...");
  
  const baseUrl = 'http://localhost:8080';
  
  // Step 1: Register user 1
  console.log("\n1. Registering user1 (testuser_authz1)...");
  const registerResult1 = await performRequest(`${baseUrl}/register`, 'POST', {
    username: 'testuser_authz1',
    password: 'password123'
  });
  console.log(`Result: ${JSON.stringify(registerResult1.data)}`);
  
  // Step 2: Login as user 1
  console.log("\n2. Logging in as user1...");
  const loginResult1 = await performRequest(`${baseUrl}/login`, 'POST', {
    username: 'testuser_authz1',
    password: 'password123'
  });
  const session1 = loginResult1.cookies.find(c => c.includes('session_id'));
  console.log(`Session 1 obtained: ${session1.slice(0, 50)}...`);
  
  // Step 3: Register user 2
  console.log("\n3. Registering user2 (testuser_authz2)...");
  const registerResult2 = await performRequest(`${baseUrl}/register`, 'POST', {
    username: 'testuser_authz2',
    password: 'password123'
  });
  console.log(`Result: ${JSON.stringify(registerResult2.data)}`);
  
  // Step 4: Login as user 2
  console.log("\n4. Logging in as user2...");
  const loginResult2 = await performRequest(`${baseUrl}/login`, 'POST', {
    username: 'testuser_authz2',
    password: 'password123'
  });
  const session2 = loginResult2.cookies.find(c => c.includes('session_id'));
  console.log(`Session 2 obtained: ${session2.slice(0, 50)}...`);
  
  // Step 5: User 1 creates a todo
  console.log("\n5. User1 creating a todo...");
  const todoByUser1 = await performRequest(`${baseUrl}/todos`, 'POST', {
    title: 'Todo from User1',
    description: 'This belongs to user1'
  }, {
    'Cookie': session1,
    'Content-Type': 'application/json'
  });
  const user1TodoId = todoByUser1.data.id;
  console.log(`User1 created todo with ID ${user1TodoId}: ${JSON.stringify(todoByUser1.data)}`);
  
  // Step 6: User 2 creates a todo
  console.log("\n6. User2 creating a todo...");
  const todoByUser2 = await performRequest(`${baseUrl}/todos`, 'POST', {
    title: 'Todo from User2', 
    description: 'This belongs to user2'
  }, {
    'Cookie': session2,
    'Content-Type': 'application/json'
  });
  const user2TodoId = todoByUser2.data.id;
  console.log(`User2 created todo with ID ${user2TodoId}: ${JSON.stringify(todoByUser2.data)}`);
  
  // Step 7: Check that user1 gets only their own todos
  console.log("\n7. User1 getting their todos...");
  const user1Todos = await performRequest(`${baseUrl}/todos`, 'GET', null, {
    'Cookie': session1
  });
  console.log(`User1 sees todos: ${JSON.stringify(user1Todos.data)}`);
  
  // Step 8: Check that user2 gets only their own todos
  console.log("\n8. User2 getting their todos...");
  const user2Todos = await performRequest(`${baseUrl}/todos`, 'GET', null, {
    'Cookie': session2
  });
  console.log(`User2 sees todos: ${JSON.stringify(user2Todos.data)}`);
  
  // Step 9: CRITICAL TEST - User2 accessing user1's specific todo (should fail)
  console.log("\n9. User2 trying to access user1's specific todo (should fail with 404)...");
  const user2AccessesUser1Todo = await performRequest(`${baseUrl}/todos/${user1TodoId}`, 'GET', null, {
    'Cookie': session2
  });
  console.log(`Status code: ${user2AccessesUser1Todo.statusCode} (Expected: 404), Response: ${JSON.stringify(user2AccessesUser1Todo.data)}`);
  
  // Step 10: CRITICAL TEST - User1 accessing user2's specific todo (should fail)
  console.log("\n10. User1 trying to access user2's specific todo (should fail with 404)...");
  const user1AccessesUser2Todo = await performRequest(`${baseUrl}/todos/${user2TodoId}`, 'GET', null, {
    'Cookie': session1
  });
  console.log(`Status code: ${user1AccessesUser2Todo.statusCode} (Expected: 404), Response: ${JSON.stringify(user1AccessesUser2Todo.data)}`);
  
  // Step 11: Test deletion isolation - each user should own only the todos they created
  console.log("\n11. User2 trying to delete user1's specific todo (should fail with 404)...");
  const user2DeletesUser1Todo = await performRequest(`${baseUrl}/todos/${user1TodoId}`, 'DELETE', null, {
    'Cookie': session2
  });
  console.log(`Status code: ${user2DeletesUser1Todo.statusCode} (Expected: 404), Response: ${JSON.stringify(user2DeletesUser1Todo.data)}`);
  
  console.log("\nAuthorization test completed.");
}

function performRequest(fullUrl, method, data, additionalHeaders = {}) {
  return new Promise((resolve, reject) => {
    const parsedUrl = url.parse(fullUrl);
    
    const options = {
      hostname: parsedUrl.hostname,
      port: parsedUrl.port || (parsedUrl.protocol === 'https:' ? 443 : 80),
      path: parsedUrl.path,
      method: method,
      headers: {
        'Content-Type': data ? 'application/json' : 'text/plain',
        ...additionalHeaders
      }
    };
    
    const req = parsedUrl.protocol === 'https:' ? https.request(options) : http.request(options);
    
    req.on('response', (res) => {
      let body = '';
      
      res.on('data', (chunk) => {
        body += chunk;
      });
      
      res.on('end', () => {
        try {
          const data = body && res.headers['content-type'] && res.headers['content-type'].includes('application/json') ? 
                     JSON.parse(body) : body;
          
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            cookies: res.headers['set-cookie'],
            data: data
          });
        } catch (e) {
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            cookies: res.headers['set-cookie'],
            data: body
          });
        }
      });
    });
    
    req.on('error', (err) => {
      reject(err);
    });
    
    if (data) {
      req.write(JSON.stringify(data));
    }
    
    req.end();
  });
}

authzTest().catch(console.error);