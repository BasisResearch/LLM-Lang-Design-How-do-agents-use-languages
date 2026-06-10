const http = require('http');
const querystring = require('querystring');

// Simple test that creates a basic request
console.log("Running simple test to verify server is functional...");

// Test data
const testData = {
    register: {
        method: 'POST',
        url: '/register',
        body: JSON.stringify({
            username: 'testuser',
            password: 'password123'
        })
    },
    login: {
        method: 'POST',
        url: '/login', 
        body: JSON.stringify({
            username: 'testuser',
            password: 'password123'
        })
    }
};

function makeRequest(options, callback) {
    const req = http.request({
        hostname: 'localhost',
        port: 8080,
        path: options.url,
        method: options.method,
        headers: {
            'Content-Type': 'application/json',
            'Content-Length': options.body ? Buffer.byteLength(options.body) : 0
        }
    }, (res) => {
        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => callback(null, res, data));
    });

    req.on('error', (e) => callback(e));

    if (options.body) {
        req.write(options.body);
    }
    req.end();
}

setTimeout(() => {
    // Try hitting a simple endpoint to see if server started
    makeRequest(testData.register, (err, res, data) => {
        if (err) {
            console.error('Error making request:', err.message);
            process.exit(1);
        }
        console.log(`Status: ${res.statusCode}`);
        console.log(`Response: ${data}`);
        process.exit(0);
    });
}, 2000); // Wait 2 seconds to ensure server starts