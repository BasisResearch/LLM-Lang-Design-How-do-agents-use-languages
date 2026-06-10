const { execSync } = require('child_process');
const fs = require('fs');

console.log("Starting simple tests...");

// Function to sleep for ms milliseconds
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function runTests() {
    // Store original state
    let cookies = {};
    
    try {
        // Start the server in the background
        console.log("Starting server...");
        const serverProcess = execSync('./run.sh --port 3001 > server.log 2>&1 &', { shell: '/bin/bash' });
        
        // Wait for server to start
        await sleep(2000);
        
        // Test 1: Register user
        console.log("Test 1: Registering valid user...");
        let response = execSync('curl -s -X POST http://localhost:3001/register -H "Content-Type: application/json" -d \'{"username":"testuser","password":"password123"}\'', { encoding: 'utf-8' });
        console.log("Response:", response);
        let result = JSON.parse(response);
        if(result.id && result.username === "testuser") {
            console.log("✓ Registration test passed");
        } else {
            console.log("✗ Registration test failed");
            return;
        }
        
        // Test 2: Register duplicate user (should fail)
        console.log("Test 2: Registering duplicate user (should fail)...");
        let resp2 = execSync('curl -s -X POST http://localhost:3001/register -H "Content-Type: application/json" -d \'{"username":"testuser","password":"password123"}\'', { encoding: 'utf-8' });
        console.log("Response:", resp2);
        let errResult = JSON.parse(resp2);
        if(errResult.error && errResult.error.includes("already exists")) {
            console.log("✓ Duplicate registration correctly failed");
        } else {
            console.log("✗ Duplicate registration should have failed");
            return;
        }
        
        // Test 3: Login
        console.log("Test 3: Logging in...");
        // Capture cookies to a file
        execSync('curl -c cookies.txt -X POST http://localhost:3001/login -H "Content-Type: application/json" -d \'{"username":"testuser","password":"password123"}\' > /dev/null 2>&1', { encoding: 'utf-8' });
        try {
            const cookieData = fs.readFileSync('cookies.txt', 'utf8');
            if(cookieData.includes('session_id')) {
                console.log("✓ Login test passed - cookie saved");
            } else {
                console.log("✗ Login test failed - no session cookie");
                return;
            }
        } catch(e) {
            console.log("✗ Login test failed - could not read cookie file:", e.message);
            return;
        }
        
        // Test 4: Access protected route with session
        console.log("Test 4: Accessing /me with authenticated session...");
        let resp4_raw = execSync('curl -b cookies.txt -s http://localhost:3001/me', { encoding: 'utf-8' });
        console.log("Response:", resp4_raw);
        let resp4 = JSON.parse(resp4_raw);
        if(resp4.id && resp4.username === "testuser") {
            console.log("✓ Authenticaton test passed");
        } else {
            console.log("✗ Authentication test failed");
            return;
        }
        
        // Test 5: Access protected route without authentication
        console.log("Test 5: Accessing /me without auth (should fail)...");
        let resp5_raw = execSync('curl -s http://localhost:3001/me', { encoding: 'utf-8' });
        console.log("Response:", resp5_raw);
        let resp5 = JSON.parse(resp5_raw);
        if(resp5.error && resp5.error.includes("Authentication")) {
            console.log("✓ Unauthorized access correctly blocked");
        } else {
            console.log("✗ Unauthorized access should have been blocked");
            return;
        }
        
        // Test 6: Create a todo
        console.log("Test 6: Creating a todo...");
        let resp6_raw = execSync('curl -b cookies.txt -s -X POST http://localhost:3001/todos -H "Content-Type: application/json" -d \'{"title":"Test Todo","description":"Test Description"}\'', { encoding: 'utf-8' });
        console.log("Response:", resp6_raw);
        let resp6 = JSON.parse(resp6_raw);
        if(resp6.id && resp6.title === "Test Todo") {
            console.log("✓ Todo creation test passed");
        } else {
            console.log("✗ Todo creation test failed");
            return;
        }
        const todoId = resp6.id;
        
        // Test 7: Get all todos
        console.log("Test 7: Getting all todos...");
        let resp7_raw = execSync('curl -b cookies.txt -s http://localhost:3001/todos', { encoding: 'utf-8' });
        console.log("Response:", resp7_raw);
        let resp7 = JSON.parse(resp7_raw);
        if(Array.isArray(resp7) && resp7.some(todo => todo.id === todoId)) {
            console.log("✓ List todos test passed");
        } else {
            console.log("✗ List todos test failed");
            return;
        }
        
        // Test 8: Get a specific todo
        console.log("Test 8: Getting specific todo...");
        let resp8_raw = execSync(`curl -b cookies.txt -s http://localhost:3001/todos/${todoId}`, { encoding: 'utf-8' });
        console.log("Response:", resp8_raw);
        let resp8 = JSON.parse(resp8_raw);
        if(resp8.id === todoId && resp8.title === "Test Todo") {
            console.log("✓ Get specific todo test passed");
        } else {
            console.log("✗ Get specific todo test failed");
            return;
        }
        
        // Test 9: Update todo
        console.log("Test 9: Updating todo...");
        let resp9_raw = execSync(`curl -b cookies.txt -s -X PUT http://localhost:3001/todos/${todoId} -H "Content-Type: application/json" -d '{"title":"Updated Title","completed":true}'`, { encoding: 'utf-8' });
        console.log("Response:", resp9_raw);
        let resp9 = JSON.parse(resp9_raw);
        if(resp9.id === todoId && resp9.title === "Updated Title" && resp9.completed === true) {
            console.log("✓ Todo update test passed");
        } else {
            console.log("✗ Todo update test failed");
            return;
        }
        
        // Test 10: Delete todo
        console.log("Test 10: Deleting todo...");
        let resp10_status = execSync(`curl -b cookies.txt -s -w "%{http_code}" -X DELETE http://localhost:3001/todos/${todoId}`, { encoding: 'utf-8' });
        console.log("Response status:", resp10_status);
        if(resp10_status.endsWith("204")) {
            console.log("✓ Todo deletion test passed");
        } else {
            console.log("✗ Todo deletion test failed");
            return;
        }
        
        console.log("All tests passed!");
    } catch (error) {
        console.error("Test execution failed:", error.message);
        console.log(error.stdout?.toString() || '');  // For debugging
    } finally {
        // Kill server process if running
        try {
            execSync('pkill -f "tsx server.ts" || true');
        } catch(e) {
            // Ignore errors when killing process
        }
    }
}

runTests();