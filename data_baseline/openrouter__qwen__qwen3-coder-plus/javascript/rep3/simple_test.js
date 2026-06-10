const { spawn } = require('child_process');
const http = require('http');

async function testServer() {
    // Test basic server functionality
    const port = 4000;
    
    // Start server
    const serverProcess = spawn('node', ['server.js', '--port', port.toString()]);
    
    // Wait a bit for the server to start
    await new Promise(resolve => setTimeout(resolve, 2000));
    
    return new Promise((resolve, reject) => {
        // Test basic connectivity
        const req = http.request({
            hostname: 'localhost',
            port: port,
            path: '/nonexistent',
            method: 'GET'
        }, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                console.log(`Status Code: ${res.statusCode}`);
                console.log(`Body: ${data}`);
                serverProcess.kill();
                resolve();
            });
        });
        
        req.on('error', (e) => {
            console.error(`Error: ${e.message}`);
            serverProcess.kill();
            reject(e);
        });
        
        req.end();
    });
}

testServer()
    .then(() => console.log('Simple test completed'))
    .catch(err => console.error('Test failed:', err));