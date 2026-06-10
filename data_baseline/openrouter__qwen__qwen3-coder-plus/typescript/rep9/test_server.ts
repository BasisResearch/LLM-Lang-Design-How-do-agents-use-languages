import { execSync } from 'child_process';
import * as http from 'http';
import * as https from 'https';
import { promisify } from 'util';

const execAsync = promisify(exec);

interface CookieJar {
  [key: string]: string;
}

async function sleep(ms: number) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function makeRequest(
  options: http.RequestOptions,
  body?: any,
  cookies: CookieJar = {}
): Promise<{ statusCode: number, headers: http.IncomingHttpHeaders, data: any, cookie: string | undefined }> {
  // Build cookie header
  const cookieHeader = Object.entries(cookies)
    .map(([key, value]) => `${key}=${value}`)
    .join('; ');

  return new Promise((resolve, reject) => {
    const mergedOptions: http.RequestOptions = {
      ...options,
      headers: {
        ...options.headers,
        ...(body ? { 'Content-Type': 'application/json' } : {}),
        ...(cookieHeader ? { cookie: cookieHeader } : {}),
      }
    };

    const lib = options.port === 443 ? https : http;

    const req = lib.request(mergedOptions, (res) => {
      let data = '';
      
      res.on('data', (chunk) => {
        data += chunk;
      });
      
      res.on('end', () => {
        try {
          resolve({
            statusCode: res.statusCode || 0,
            headers: res.headers,
            data: data ? JSON.parse(data) : null,
            cookie: res.headers['set-cookie'] && Array.isArray(res.headers['set-cookie']) ? res.headers['set-cookie'][0].split(';')[0] : undefined
          });
        } catch (err) {
          resolve({
            statusCode: res.statusCode || 0,
            headers: res.headers,
            data: data,
            cookie: res.headers['set-cookie'] && Array.isArray(res.headers['set-cookie']) ? res.headers['set-cookie'][0].split(';')[0] : undefined
          });
        }
      });
    });

    req.on('error', (error) => {
      reject(error);
    });

    if (body) {
      req.write(JSON.stringify(body));
    }
    
    req.end();
  });
}

async function runTest() {
  console.log("Starting server...");
  
  // Start the server in the background
  const serverProcess = execSync('./run.sh --port 3001 > server.log 2>&1 &', { shell: '/bin/bash' });
  
  // Give the server time to start
  await sleep(2000);
  
  let sessionId: string | undefined;
  let.userId: number;
  let todoId: number;
  
  try {
    // Test 1: Register a new user
    console.log("\n--- Test 1: Register ---");
    let response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/register',
      method: 'POST'
    }, {
      username: "testuser",
      password: "secret123"
    });
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 201 || !response.data.id) {
      throw new Error(`Register failed: ${response.data}`);
    }
    
    userId = response.data.id;
    
    // Test 2: Login
    console.log("\n--- Test 2: Login ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/login',
      method: 'POST'
    }, {
      username: "testuser",
      password: "secret123"
    });
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 200 || !response.cookie) {
      throw new Error(`Login failed: ${response.data}`);
    }
    
    sessionId = response.cookie.split('=')[1];
    console.log("Session ID:", sessionId);
    
    // Test 3: Get current user info
    console.log("\n--- Test 3: Get user info (/me) ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/me',
      method: 'GET'
    }, undefined, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 200 || response.data.id !== userId) {
      throw new Error(`Get user info failed: ${response.data}`);
    }
    
    // Test 4: Create a todo
    console.log("\n--- Test 4: Create TODO ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/todos',
      method: 'POST'
    }, {
      title: "Buy groceries",
      description: "Milk, eggs, bread"
    }, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 201 || response.data.title !== "Buy groceries") {
      throw new Error(`Create todo failed: ${response.data}`);
    }
    
    todoId = response.data.id;
    
    // Test 5: Get all todos
    console.log("\n--- Test 5: Get all TODOs ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/todos',
      method: 'GET'
    }, undefined, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}, Count: ${response.data.length}`);
    if (response.statusCode !== 200 || response.data.length !== 1) {
      throw new Error(`Get todos failed: ${response.data}`);
    }
    
    // Test 6: Get specific todo
    console.log("\n--- Test 6: Get specific TODO ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: `/todos/${todoId}`,
      method: 'GET'
    }, undefined, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 200 || response.data.id !== todoId) {
      throw new Error(`Get specific todo failed: ${response.data}`);
    }
    
    // Test 7: Update todo
    console.log("\n--- Test 7: Update TODO ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: `/todos/${todoId}`,
      method: 'PUT'
    }, {
      completed: true,
      description: "Updated description"
    }, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 200 || !response.data.completed) {
      throw new Error(`Update todo failed: ${response.data}`);
    }
    
    // Test 8: Change password
    console.log("\n--- Test 8: Change password ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/password',
      method: 'PUT'
    }, {
      old_password: "secret123",
      new_password: "newpassword123"
    }, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 200) {
      throw new Error(`Change password failed: ${response.data}`);
    }
    
    // Test 9: Logout
    console.log("\n--- Test 9: Logout ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/logout',
      method: 'POST'
    }, undefined, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 200) {
      throw new Error(`Logout failed: ${response.data}`);
    }
    
    // Test 10: Try to access protected endpoint without auth -> should fail
    console.log("\n--- Test 10: Access protected endpoint without auth ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/me',
      method: 'GET'
    });
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 401) {
      throw new Error(`Expected 401 without auth but got ${response.statusCode}: ${response.data}`);
    }
    
    // Test 11: Login again with new password and access
    console.log("\n--- Test 11: Login with new password ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/login',
      method: 'POST'
    }, {
      username: "testuser",
      password: "newpassword123"
    });
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 200) {
      throw new Error(`Login with new password failed: ${response.data}`);
    }
    
    sessionId = response.cookie?.split('=')[1];
    
    // Re-access /me endpoint
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: '/me',
      method: 'GET'
    }, undefined, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status after re-authenticating: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 200) {
      throw new Error(`Access /me with new session failed: ${response.data}`);
    }
    
    // Test 12: Delete the todo
    console.log("\n--- Test 12: Delete TODO ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: `/todos/${todoId}`,
      method: 'DELETE'
    }, undefined, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}`);
    if (response.statusCode !== 204) {
      throw new Error(`Delete todo failed: expected 204 but got ${response.statusCode}`);
    }
    
    // Test 13: Try to access deleted todo -> should fail
    console.log("\n--- Test 13: Access deleted TODO ---");
    response = await makeRequest({
      hostname: 'localhost',
      port: 3001,
      path: `/todos/${todoId}`,
      method: 'GET'
    }, undefined, sessionId ? { session_id: sessionId } : {});
    
    console.log(`Status: ${response.statusCode}, Data: `, response.data);
    if (response.statusCode !== 404) {
      throw new Error(`Expected 404 for deleted todo but got ${response.statusCode}: ${response.data}`);
    }
    
    console.log("\n--- All tests passed successfully! ---");
    
  } catch (err) {
    console.error("\n--- Test failed:", err.message);
    throw err;
  } finally {
    // Stop the server
    try {
      execSync('pkill -f "tsx server.ts"', { stdio: 'ignore' });
    } catch (err) {
      // Ignore errors when killing process
    }
  }
}

runTest()
  .then(() => console.log("Tests completed successfully"))
  .catch(err => {
    console.error("Error during testing:", err);
    process.exit(1);
  });