const http = require('http');
const crypto = require('crypto');

// Test client for verification 
async function runVerificationTests() {
    // Configuration
    const PORT = 54322;
    const BASE_URL = `http://localhost:${PORT}`;
    
    // Start server instance in background
    const serverModule = require('./server.js');
    const server = serverModule.createServer(PORT);
    
    // Small delay for server to start
    await new Promise(resolve => setTimeout(resolve, 1000));
    
    console.log("Starting API verification tests...\n");
    
    // Test 1: Register endpoint
    console.log("1. Testing POST /register");
    try {
        const userCreds = {
            username: `testuser_${Date.now()}`,
            password: "securePassword123"
        };
        
        const regResult = await makeRequest(`${BASE_URL}/register`, 'POST', userCreds);
        console.log("   Response:", regResult.data);
        
        if (regResult.statusCode !== 201 || !regResult.data.id || regResult.data.username !== userCreds.username) {
            throw new Error(`Registration failed: expected 201 with user data`);
        }
        
        console.log("   ✅ Registration successful\n");
        
        // Store user credentials for next tests
        const userId = regResult.data.id;
        
        // Test 2: Login
        console.log("2. Testing POST /login");
        const loginResult = await makeRequest(`${BASE_URL}/login`, 'POST', userCreds);
        console.log("   Response:", loginResult.data);
        
        if (loginResult.statusCode !== 200 || loginResult.data.id !== userId) {
            throw new Error(`Login failed: expected 200 with user id ${userId}`);
        }
        
        // Extract session cookie for future requests
        const cookieHeaders = loginResult.headers['set-cookie'];
        let sessionCookie = null;
        if (Array.isArray(cookieHeaders)) {
            sessionCookie = cookieHeaders.find(c => c.includes('session_id'));
        } else if (typeof cookieHeaders === 'string'){
            sessionCookie = cookieHeaders.includes('session_id') ? cookieHeaders : null;
        }
        
        if (!sessionCookie) {
            throw new Error('No session cookie received');
        }
        
        // Clean up to extract session ID only
        const sessionId = sessionCookie.split(';')[0].split('=')[1];
        const cookies = `session_id=${sessionId}`;
        
        console.log("   ✅ Login successful\n");
        
        // Test 3: Test /me endpoint with authentication
        console.log("3. Testing GET /me");
        const meResult = await makeRequest(`${BASE_URL}/me`, 'GET', null, cookies);
        console.log("   Response:", meResult.data);
        
        if (meResult.statusCode !== 200 || meResult.data.id !== userId) {
            throw new Error(`/me failed: unexpected response`);
        }
        console.log("   ✅ Me endpoint working\n");
        
        // Test 4: Test creating a todo
        console.log("4. Testing POST /todos");
        const todoInfo = {
            title: "Test Todo",
            description: "A sample todo item"
        };
        
        const todoResult = await makeRequest(`${BASE_URL}/todos`, 'POST', todoInfo, cookies);
        console.log("   Response:", todoResult.data);
        
        if (todoResult.statusCode !== 201 || 
            todoResult.data.title !== todoInfo.title ||
            todoResult.data.description !== todoInfo.description ||
            todoResult.data.completed !== false) {
            throw new Error(`Todo creation failed`);
        }
        
        const todoId = todoResult.data.id;
        console.log(`   ✅ Todo creation successful (ID: ${todoId})\n`);
        
        // Test 5: Get the todo
        console.log("5. Testing GET /todos/:id");
        const getTodoResult = await makeRequest(`${BASE_URL}/todos/${todoId}`, 'GET', null, cookies);
        console.log("   Response:", getTodoResult.data);
        
        if (getTodoResult.statusCode !== 200 || getTodoResult.data.id !== todoId) {
            throw new Error(`Get single todo failed`);
        }
        console.log("   ✅ Get single todo working\n");
        
        // Test 6: Update the todo
        console.log("6. Testing PUT /todos/:id");
        const updateInfo = {
            title: "Updated Todo",
            completed: true
        };
        
        const updateResult = await makeRequest(`${BASE_URL}/todos/${todoId}`, 'PUT', updateInfo, cookies);
        console.log("   Response:", updateResult.data);
        
        if (updateResult.statusCode !== 200 || 
            updateResult.data.title !== "Updated Todo" || 
            updateResult.data.completed !== true) {
            throw new Error(`Todo update failed`);
        }
        console.log("   ✅ Update todo successful\n");
        
        // Test 7: Delete the todo
        console.log("7. Testing DELETE /todos/:id");
        const deleteResult = await makeRequest(`${BASE_URL}/todos/${todoId}`, 'DELETE', null, cookies);
        
        if (deleteResult.statusCode !== 204) {
            throw new Error(`Todo deletion failed, got status: ${deleteResult.statusCode}`);
        }
        console.log("   ✅ Todo deletion successful (204)\n");
        
        // Test 8: Try to access deleted todo
        console.log("8. Verifying deleted todo is gone");
        const accessDeletedResult = await makeRequest(`${BASE_URL}/todos/${todoId}`, 'GET', null, cookies);
        
        if (accessDeletedResult.statusCode !== 404) {
            throw new Error(`Deleted todo still accessible`);
        }
        console.log("   ✅ Deleted todo properly inaccessible\n");
        
        // Test 9: Test protected endpoints without auth
        console.log("9. Testing authentication protection");
        const unauthResult = await makeRequest(`${BASE_URL}/me`, 'GET'); // No cookie
        
        if (unauthResult.statusCode !== 401) {
            throw new Error(`Authentication protection failed`);
        }
        console.log("   ✅ Unauthenticated requests properly blocked\n");
        
        console.log("🎉 All verification tests passed!");
        
    } catch (error) {
        console.error("❌ Verification failed:", error.message);
        process.exit(1);
    } finally {
        // Cleanup
        server.close(() => {
            console.log("\nServer closed.");
        });
    }
}

// Helper function to make HTTP requests
function makeRequest(url, method, data = null, cookies = null) {
    return new Promise((resolve, reject) => {
        const parsedUrl = new URL(url);
        
        const options = {
            hostname: parsedUrl.hostname,
            port: parsedUrl.port,
            path: parsedUrl.pathname + parsedUrl.search,
            method: method,
            headers: {
                'Content-Type': 'application/json'
            }
        };
        
        if (cookies) {
            options.headers['Cookie'] = cookies;
        }
        
        const req = http.request(options, (res) => {
            let data = '';
            
            res.on('data', (chunk) => {
                data += chunk;
            });
            
            res.on('end', () => {
                try {
                    let responseJson = null;
                    
                    // Only attempt JSON parse if there's content type indicating it
                    if (res.headers['content-type'] && res.headers['content-type'].includes('application/json') && data) {
                        try {
                            responseJson = JSON.parse(data);
                        } catch (e) {
                            // Sometimes content-type is set but no actual JSON
                        }
                    }
                    
                    resolve({
                        statusCode: res.statusCode,
                        headers: res.headers,
                        data: responseJson
                    });
                } catch (e) {
                    reject(e);
                }
            });
        });
        
        req.on('error', (e) => {
            reject(e);
        });
        
        if (data) {
            req.write(JSON.stringify(data));
        }
        
        req.end();
    });
}

// Run the verification
runVerificationTests();