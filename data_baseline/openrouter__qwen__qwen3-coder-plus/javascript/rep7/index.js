#!/usr/bin/env node

const TodoServer = require('./server');

// Parse command line arguments
const args = process.argv.slice(2);
let port = 8000; // Default port

for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
        port = parseInt(args[i + 1], 10);
        if (isNaN(port)) {
            console.error('Error: Port must be a number');
            process.exit(1);
        }
        break;
    }
}

// Start the server
const server = new TodoServer();
server.start(port);