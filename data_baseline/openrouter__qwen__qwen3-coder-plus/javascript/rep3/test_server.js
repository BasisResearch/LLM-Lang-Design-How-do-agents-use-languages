const { spawn } = require('child_process');
const path = require('path');

// Test script to verify our API implementation

async function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function testImplementation() {
    console.log('Starting server tests...');

    // Start the server on a random available port
    const testPort = 4567;
    const env = { ...process.env, PORT: testPort.toString() };
    const serverProcess = spawn('node', ['server.js', '--port', testPort.toString()], { cwd: process.cwd() });

    let serverStarted = false;
    serverProcess.stdout.on('data', (data) => {
        if (data.toString().includes(`Server running on 0.0.0.0:${testPort}`)) {
            serverStarted = true;
            console.log('✓ Server started successfully on port:', testPort);
        }
        console.log(`Server output: ${data}`);
    });

    serverProcess.stderr.on('data', (data) => {
        console.error(`Server error: ${data}`);
    });

    // Wait for server to start
    while (!serverStarted) {
        await sleep(100);
    }
    await sleep(100); // Additional wait for port to be fully bound

    // Import here after server starts since we need the modules
    const http = require('http');
    const { once } = require('events');

    async function makeRequest(options, postData = null) {
        return new Promise((resolve, reject) => {
            const req = http.request(options, (res) => {
                let data = '';
                res.on('data', (chunk) => {
                    data += chunk;
                });
                res.on('end', () => {
                    try {
                        const result = { 
                            statusCode: res.statusCode, 
                            headers: res.headers,
                            body: data ? JSON.parse(data) : null
                        };
                        resolve(result);
                    } catch (e) {
                        resolve({ 
                            statusCode: res.statusCode, 
                            headers: res.headers,
                            body: data  // Return raw data if not JSON
                        });
                    }
                });
            });

            req.on('error', (e) => {
                reject(e);
            });

            if (postData) {
                req.write(postData);
            }
            
            req.end();
        });
    }

    // Test variables to hold state between tests
    let user1SessionCookie = null;
    let user2SessionCookie = null;
    let user1Credentials = { username: 'testuser1', password: 'password123' };
    let user2Credentials = { username: 'testuser2', password: 'password456' };
    let createdTodoId = null;

    try {
        console.log('\n🧪 Testing Registration...');
        
        // Test registration of user 1
        let response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/register',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            }
        }, JSON.stringify(user1Credentials));
        
        if (response.statusCode === 201 && response.body.id && response.body.username === user1Credentials.username) {
            console.log('✓ Registration success for user 1');
        } else {
            console.log('✗ Registration failed for user 1:', response);
            throw new Error('Registration Test Failed');
        }

        // Test registration of user 2
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/register',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            }
        }, JSON.stringify(user2Credentials));
        
        if (response.statusCode === 201 && response.body.id && response.body.username === user2Credentials.username) {
            console.log('✓ Registration success for user 2');
        } else {
            console.log('✗ Registration failed for user 2:', response);
            throw new Error('Registration Test Failed');
        }

        // Test registration conflict
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/register',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            }
        }, JSON.stringify(user1Credentials));  // Try to re-register same user
        
        if (response.statusCode === 409 && response.body.error === 'Username already exists') {
            console.log('✓ Conflict handling success for duplicate username');
        } else {
            console.log('✗ Conflict test failed:', response);
            throw new Error('Conflict Test Failed');
        }

        console.log('\n🧪 Testing Login...');
        
        // Test login for user 1
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/login',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            }
        }, JSON.stringify(user1Credentials));
        
        if (response.statusCode === 200 && response.headers['set-cookie'] && 
            response.body.id && response.body.username === user1Credentials.username) {
            user1SessionCookie = response.headers['set-cookie'][0].split(';')[0];  // Extract cookie
            console.log('✓ Login success for user 1 - Session:', user1SessionCookie);
        } else {
            console.log('✗ Login failed for user 1:', response);
            throw new Error('Login Test Failed');
        }

        // Test login for user 2
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/login',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            }
        }, JSON.stringify(user2Credentials));
        
        if (response.statusCode === 200 && response.headers['set-cookie'] &&
            response.body.id && response.body.username === user2Credentials.username) {
            user2SessionCookie = response.headers['set-cookie'][0].split(';')[0];  // Extract cookie
            console.log('✓ Login success for user 2 - Session:', user2SessionCookie);
        } else {
            console.log('✗ Login failed for user 2:', response);
            throw new Error('Login Test Failed');
        }

        // Test invalid credentials
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/login',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            }
        }, JSON.stringify({ username: user1Credentials.username, password: 'wrongpass' }));
        
        if (response.statusCode === 401 && response.body.error === 'Invalid credentials') {
            console.log('✓ Invalid credentials handled correctly');
        } else {
            console.log('✗ Invalid credentials test failed:', response);
            throw new Error('Invalid Credentials Test Failed');
        }

        console.log('\n🧪 Testing Authentication Required Routes...');
        
        // Test /me without authentication
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/me',
            method: 'GET'
        });
        
        if (response.statusCode === 401 && response.body.error === 'Authentication required') {
            console.log('✓ Auth required enforced on /me');
        } else {
            console.log('✗ Auth required test failed on /me:', response);
            throw new Error('Auth Required Test Failed');
        }

        // Test protected routes with auth (get user info)
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/me',
            method: 'GET',
            headers: {
                'Cookie': user1SessionCookie
            }
        });
        
        if (response.statusCode === 200 && response.body.username === user1Credentials.username) {
            console.log('✓ /me returns correct user info');
        } else {
            console.log('✗ /me test failed:', response);
            throw new Error('/me Test Failed');
        }

        console.log('\n🧪 Testing Todo Creation & Retrieval...');
        
        // Test creating a todo
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/todos',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Cookie': user1SessionCookie
            }
        }, JSON.stringify({
            title: 'Test Todo',
            description: 'This is a test todo item'
        }));
        
        if (response.statusCode === 201 && response.body.title === 'Test Todo' && 
            response.body.description === 'This is a test todo item' && 
            response.body.completed === false) {
            createdTodoId = response.body.id;
            console.log('✓ Todo creation successful - ID:', createdTodoId);
        } else {
            console.log('✗ Todo creation failed:', response);
            throw new Error('Todo Creation Test Failed');
        }

        // Test creating todo with empty title (should fail)
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/todos',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Cookie': user1SessionCookie
            }
        }, JSON.stringify({
            title: '',
            description: 'This should fail'
        }));
        
        if (response.statusCode === 400 && response.body.error === 'Title is required') {
            console.log('✓ Todo creation validation works');
        } else {
            console.log('✗ Todo validation test failed:', response);
            throw new Error('Todo Validation Test Failed');
        }

        // Test getting user todos
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/todos',
            method: 'GET',
            headers: {
                'Cookie': user1SessionCookie
            }
        });
        
        if (response.statusCode === 200 && Array.isArray(response.body) && response.body.length > 0) {
            console.log('✓ Todo retrieval successful - Count:', response.body.length);
        } else {
            console.log('✗ Todo retrieval failed:', response);
            throw new Error('Todo Retrieval Test Failed');
        }

        console.log('\n🧪 Testing Todo CRUD Operations...');
        
        // Test getting a specific todo
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: `/todos/${createdTodoId}`,
            method: 'GET',
            headers: {
                'Cookie': user1SessionCookie
            }
        });
        
        if (response.statusCode === 200 && response.body.id === createdTodoId) {
            console.log('✓ Get specific todo successful');
        } else {
            console.log('✗ Get specific todo failed:', response);
            throw new Error('Get Todo Test Failed');
        }

        // Test updating a specific todo
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: `/todos/${createdTodoId}`,
            method: 'PUT',
            headers: {
                'Content-Type': 'application/json',
                'Cookie': user1SessionCookie
            }
        }, JSON.stringify({
            title: 'Updated Title',
            completed: true
        }));
        
        if (response.statusCode === 200 && response.body.title === 'Updated Title' && 
            response.body.completed === true && response.body.id === createdTodoId) {
            console.log('✓ Todo update successful');
        } else {
            console.log('✗ Todo update failed:', response);
            throw new Error('Todo Update Test Failed');
        }

        // Test updating with empty title (should fail)
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: `/todos/${createdTodoId}`,
            method: 'PUT',
            headers: {
                'Content-Type': 'application/json',
                'Cookie': user1SessionCookie
            }
        }, JSON.stringify({
            title: ''
        }));
        
        if (response.statusCode === 400 && response.body.error === 'Title is required') {
            console.log('✓ Todo update validation works');
        } else {
            console.log('✗ Todo update validation test failed:', response);
            throw new Error('Todo Update Validation Test Failed');
        }

        // Test accessing another user's todo (should fail with 404)
        const user2Response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/todos',
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Cookie': user2SessionCookie
            }
        }, JSON.stringify({
            title: 'User2 Todo'
        }));
        
        if (user2Response.statusCode === 201 && user2Response.body.title === 'User2 Todo') {
            const user2TodoId = user2Response.body.id;
            console.log('✓ User2 todo created - ID:', user2TodoId);
            
            // Now test that user1 can't access user2's todo
            response = await makeRequest({
                hostname: 'localhost',
                port: testPort,
                path: `/todos/${user2TodoId}`,
                method: 'GET',
                headers: {
                    'Cookie': user1SessionCookie  // User1 trying to access User2's todo
                }
            });
            
            if (response.statusCode === 404 && response.body.error === 'Todo not found') {
                console.log('✓ Cross-user protection successful (get)');
            } else {
                console.log('✗ Cross-user protection failed (get):', response);
                throw new Error('Cross-user Protection Test Failed');
            }
            
            // Also test update
            response = await makeRequest({
                hostname: 'localhost',
                port: testPort,
                path: `/todos/${user2TodoId}`,
                method: 'PUT',
                headers: {
                    'Content-Type': 'application/json',
                    'Cookie': user1SessionCookie  // User1 trying to update User2's todo
                },
                body: JSON.stringify({ title: 'Hacked title' })
            });
            
            if (response.statusCode === 404 && response.body.error === 'Todo not found') {
                console.log('✓ Cross-user protection successful (update)');
            } else {
                console.log('✗ Cross-user protection failed (update):', response);
                throw new Error('Cross-user Protection Test Failed');
            }
            
        } else {
            console.log('✗ User2 todo creation failed:', user2Response);
            throw new Error('User2 Todo Creation Failed');
        }

        // Test deleting a todo
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: `/todos/${createdTodoId}`,
            method: 'DELETE',
            headers: {
                'Cookie': user1SessionCookie
            }
        });
        
        if (response.statusCode === 204) {
            console.log('✓ Todo deletion successful');
        } else {
            console.log('✗ Todo deletion failed:', response);
            throw new Error('Todo Deletion Test Failed');
        }

        // Test that deleted todo doesn't exist anymore
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: `/todos/${createdTodoId}`,
            method: 'GET',
            headers: {
                'Cookie': user1SessionCookie
            }
        });
        
        if (response.statusCode === 404 && response.body.error === 'Todo not found') {
            console.log('✓ Deleted todo properly inaccessible');
        } else {
            console.log('✗ Deleted todo still accessible:', response);
            throw new Error('Deleted Todo Accessibility Test Failed');
        }

        console.log('\n🧪 Testing Password Change...');
        
        // Test changing password
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/password',
            method: 'PUT',
            headers: {
                'Content-Type': 'application/json',
                'Cookie': user1SessionCookie
            }
        }, JSON.stringify({
            old_password: user1Credentials.password,
            new_password: 'newpassword123'
        }));
        
        if (response.statusCode === 200) {
            console.log('✓ Password change successful');
            
            // Now try to login with new password
            response = await makeRequest({
                hostname: 'localhost',
                port: testPort,
                path: '/login',
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                }
            }, JSON.stringify({...user1Credentials, password: 'newpassword123'}));
            
            if (response.statusCode === 200) {
                console.log('✓ New password login successful');
                
                // Update session for later tests
                user1SessionCookie = response.headers['set-cookie'][0].split(';')[0];
            } else {
                console.log('✗ New password login failed:', response);
                throw new Error('New Password Login Test Failed');
            }
        } else {
            console.log('✗ Password change failed:', response);
            throw new Error('Password Change Test Failed');
        }

        console.log('\n🧪 Testing Logout...');
        
        // Test logout
        response = await makeRequest({
            hostname: 'localhost',
            port: testPort,
            path: '/logout',
            method: 'POST',
            headers: {
                'Cookie': user1SessionCookie
            }
        });
        
        if (response.statusCode === 200) {
            console.log('✓ Logout successful');
            
            // Verify session invalidation by attempting to access protected resource
            response = await makeRequest({
                hostname: 'localhost',
                port: testPort,
                path: '/me',
                method: 'GET',
                headers: {
                    'Cookie': user1SessionCookie  // Using invalidated session
                }
            });
            
            if (response.statusCode === 401 && response.body.error === 'Authentication required') {
                console.log('✓ Session properly invalidated after logout');
            } else {
                console.log('✗ Session not invalidated after logout:', response);
                throw new Error('Session Invalidating After Logout Test Failed');
            }
        } else {
            console.log('✗ Logout failed:', response);
            throw new Error('Logout Test Failed');
        }

        console.log('\n🎉 All tests passed!');
        
    } catch (error) {
        console.error('\n💥 Test failed:', error.message);
        serverProcess.kill();
        process.exit(1);
    }

    // Clean up: Kill the server process
    serverProcess.kill();
    console.log('\n✅ Server terminated.');
}

testImplementation();