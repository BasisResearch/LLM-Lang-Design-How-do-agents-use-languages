#!/usr/bin/env node

import app from './server';

// Parse command line arguments
const args = process.argv.slice(2);
let port = 3000; // Default port

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && i + 1 < args.length) {
    const portArg = parseInt(args[i + 1], 10);
    if (!isNaN(portArg) && portArg > 0) {
      port = portArg;
      i++; // Skip the next argument as it's the port value
    } else {
      console.error(`Invalid port: ${args[i + 1]}`);
      process.exit(1);
    }
  }
}

const server = app.listen(port, '0.0.0.0', () => {
  console.log(`Server running on 0.0.0.0:${port}`);
});