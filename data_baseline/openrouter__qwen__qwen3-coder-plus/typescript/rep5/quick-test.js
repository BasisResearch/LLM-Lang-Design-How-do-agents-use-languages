// Quick integration test for the server 
const http = require('http');
const https = require('https');
const url = require('url');

async function quickTest() {
  console.log("Starting quick integration test...");
  
  const baseUrl = 'http://localhost:8080';
  
  // Step 1: Register user
  console.log("\n1. Registering user...");
  const registerResult = await performRequest(`${baseUrl}/register`, 'POST', {
    username: 'testuser_quick',
    password: 'password123'
  });
  console.log(`Result: ${JSON.stringify(registerResult)}`);
  
  // Step 2: Login to get session
  console.log("\n2. Logging in...");
  const loginResult = await performRequest(`${baseUrl}/login`, 'POST', {
    username: 'testuser_quick',
    password: 'password123'
  });
  console.log(`Result: ${JSON.stringify(loginResult.data)}`);
  console.log(`Cookies: ${JSON.stringify(loginResult.cookies)}`);
  
  // Extract session cookie 
  let sessionCookie = null;
  if (loginResult.cookies && Array.isArray(loginResult.cookies)) {
    sessionCookie = loginResult.cookies.find(c => c.includes('session_id'));
  }
  console.log(`Session cookie found: ${sessionCookie}`);
  
  // Step 3: Get /me with session cookie
  console.log("\n3. Accessing /me with session...");
  const meResult = await performRequest(`${baseUrl}/me`, 'GET', null, {
    'Cookie': sessionCookie
  });
  console.log(`Result: ${JSON.stringify(meResult.data)}`);
  
  // Step 4: Create a todo
  console.log("\n4. Creating todo...");
  const todoResult = await performRequest(`${baseUrl}/todos`, 'POST', {
    title: 'Test Todo',
    description: 'Description of test todo'
  }, {
    'Cookie': sessionCookie,
    'Content-Type': 'application/json'
  });
  console.log(`Result: ${JSON.stringify(todoResult.data)}`);
  
  // Step 5: Get todos
  console.log("\n5. Getting todos...");
  const todosResult = await performRequest(`${baseUrl}/todos`, 'GET', null, {
    'Cookie': sessionCookie
  });
  console.log(`Result: ${JSON.stringify(todosResult.data)}`);
  
  console.log("\nIntegration test completed.");
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

quickTest().catch(console.error);