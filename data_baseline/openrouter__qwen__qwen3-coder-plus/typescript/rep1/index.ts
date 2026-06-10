#!/usr/bin/env node

import app from './server';

const args = process.argv.slice(2);

// Parse command line arguments
let port = 3000; // Default port

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && i + 1 < args.length) {
    port = parseInt(args[i + 1], 10);
    if (isNaN(port)) {
      console.error('Error: Port must be a number');
      process.exit(1);
    }
    i++; // Skip next argument since it's the port value
  }
}

// Start the server
app.listen(port, '0.0.0.0', () => {
  console.log(`Server running on http://0.0.0.0:${port}`);
});