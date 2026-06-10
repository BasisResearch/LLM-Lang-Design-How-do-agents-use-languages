const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
let users = [];
let todos = [];
let sessions = new Map(); // session_id -> userId
let nextUserId = 1;
let nextTodoId = 1;

function generateTimestamp() {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z'); // Remove fractional seconds to match format
}

function validateUsername(username) {
  if (!username || typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  return /^[a-zA-Z0-9_]+$/.test(username);
}

function extractSessionId(cookieHeader) {
  if (!cookieHeader) return null;
  
  const cookies = cookieHeader.split(';');
  for (const cookie of cookies) {
    const [name, value] = cookie.trim().split('=');
    if (name === 'session_id') {
      return value;
    }
  }
  return null;
}

function authenticate(sessionId) {
  if (!sessionId) return null;
  const userId = sessions.get(sessionId);
  if (userId === undefined) return null;
  return users.find(user => user.id === userId) || null;
}

function getUserTodos(userId) {
  return todos.filter(todo => todo.userId === userId);
}

function getTodoById(id, userId) {
  return todos.find(todo => todo.id === parseInt(id) && todo.userId === userId);
}

function respondJSON(res, statusCode, data) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  if (data !== undefined) {
    res.end(JSON.stringify(data));
  } else {
    res.end();
  }
}

function respondError(res, statusCode, message) {
  respondJSON(res, statusCode, { error: message });
}

function parseRequestBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk.toString();
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (err) {
        reject(err);
      }
    });
  });
}

async function handleRequest(req, res) {
  const parsedUrl = url.parse(req.url, true);
  const path = parsedUrl.pathname;
  const method = req.method;

  // Extract session ID from cookie
  const sessionId = extractSessionId(req.headers.cookie);

  // Define protected endpoints
  const protectedEndpoints = [
    '/me', '/password', '/logout',
    '/todos', 
    /^\/todos\/\d+$/,
    /^\/todos\/\d+$/,
    /^\/todos\/\d+$/
  ];

  // Check if this is a protected endpoint
  let requiresAuth = false;
  for (const endpoint of protectedEndpoints) {
    if (typeof endpoint === 'string') {
      if (path.startsWith(endpoint)) {
        requiresAuth = true;
        break;
      }
    } else {
      if (endpoint.test(path)) {
        requiresAuth = true;
        break;
      }
    }
  }

  // Authenticate if needed
  let user = null;
  if (requiresAuth) {
    user = authenticate(sessionId);
    if (!user) {
      respondError(res, 401, 'Authentication required');
      return;
    }
  }

  try {
    // Register endpoint
    if (method === 'POST' && path === '/register') {
      const body = await parseRequestBody(req);
      
      const { username, password } = body;
      
      // Validate username
      if (!validateUsername(username)) {
        respondError(res, 400, 'Invalid username');
        return;
      }
      
      // Validate password length
      if (!password || typeof password !== 'string' || password.length < 8) {
        respondError(res, 400, 'Password too short');
        return;
      }
      
      // Check if username already exists
      if (users.some(u => u.username === username)) {
        respondError(res, 409, 'Username already exists');
        return;
      }
      
      // Create user
      const newUser = {
        id: nextUserId++,
        username: username
      };
      
      // Store the password hashed
      const hashedPassword = crypto.createHash('sha256').update(password).digest('hex');
      users.push({
        id: newUser.id,
        username: newUser.username,
        password: hashedPassword
      });
      
      respondJSON(res, 201, newUser);
      return;
    }

    // Login endpoint
    if (method === 'POST' && path === '/login') {
      const body = await parseRequestBody(req);
      
      const { username, password } = body;
      
      // Find user
      const userRecord = users.find(u => u.username === username);
      if (!userRecord) {
        respondError(res, 401, 'Invalid credentials');
        return;
      }
      
      // Check password
      const hashedPassword = crypto.createHash('sha256').update(password).digest('hex');
      if (hashedPassword !== userRecord.password) {
        respondError(res, 401, 'Invalid credentials');
        return;
      }
      
      // Generate new session ID
      const newSessionId = crypto.randomUUID();
      
      // Store session
      sessions.set(newSessionId, userRecord.id);
      
      // Set cookie and respond with user
      const responseUser = {
        id: userRecord.id,
        username: userRecord.username
      };
      
      res.setHeader('Set-Cookie', `session_id=${newSessionId}; Path=/; HttpOnly`);
      respondJSON(res, 200, responseUser);
      return;
    }

    // Logout endpoint
    if (method === 'POST' && path === '/logout') {
      // Remove session if it exists
      if (sessionId) {
        sessions.delete(sessionId);
      }
      
      respondJSON(res, 200, {});
      return;
    }

    // Get me endpoint
    if (method === 'GET' && path === '/me') {
      respondJSON(res, 200, {
        id: user.id,
        username: user.username
      });
      return;
    }

    // Change password endpoint
    if (method === 'PUT' && path === '/password') {
      const body = await parseRequestBody(req);
      
      const { old_password, new_password } = body;
      
      // Validate old password
      if (!old_password || typeof old_password !== 'string') {
        respondError(res, 401, 'Invalid credentials');
        return;
      }
      
      // Hash old password and compare
      const oldHashed = crypto.createHash('sha256').update(old_password).digest('hex');
      const currentUserRecord = users.find(u => u.id === user.id);
      if (oldHashed !== currentUserRecord.password) {
        respondError(res, 401, 'Invalid credentials');
        return;
      }
      
      // Validate new password length
      if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
        respondError(res, 400, 'Password too short');
        return;
      }
      
      // Update password
      const newHashed = crypto.createHash('sha256').update(new_password).digest('hex');
      currentUserRecord.password = newHashed;
      
      respondJSON(res, 200, {});
      return;
    }

    // List todos endpoint
    if (method === 'GET' && path === '/todos') {
      const userTodos = getUserTodos(user.id);
      respondJSON(res, 200, userTodos);
      return;
    }

    // Create todo endpoint
    if (method === 'POST' && path === '/todos') {
      const body = await parseRequestBody(req);
      
      const { title, description } = body;
      
      // Validate title
      if (!title || typeof title !== 'string' || title.trim() === '') {
        respondError(res, 400, 'Title is required');
        return;
      }
      
      // Use default empty string for description if not provided
      const desc = description ? String(description) : "";
      
      // Create new todo
      const timestamp = generateTimestamp();
      const newTodo = {
        id: nextTodoId++,
        title: String(title),
        description: desc,
        completed: false,
        created_at: timestamp,
        updated_at: timestamp,
        userId: user.id // Track owner
      };
      
      todos.push(newTodo);
      respondJSON(res, 201, newTodo);
      return;
    }

    // Get individual todo endpoint
    if (method === 'GET' && /^\/todos\/\d+$/.test(path)) {
      const id = path.split('/')[2];
      const todo = getTodoById(id, user.id);
      
      if (!todo) {
        respondError(res, 404, 'Todo not found');
        return;
      }
      
      respondJSON(res, 200, todo);
      return;
    }

    // Update individual todo endpoint
    if (method === 'PUT' && /^\/todos\/\d+$/.test(path)) {
      const id = path.split('/')[2];
      const existingTodo = getTodoById(id, user.id);
      
      if (!existingTodo) {
        respondError(res, 404, 'Todo not found');
        return;
      }
      
      const body = await parseRequestBody(req);
      
      // Validate title if provided
      if ('title' in body && (body.title === undefined || body.title === null || String(body.title).trim() === '')) {
        respondError(res, 400, 'Title is required');
        return;
      }
      
      // Update fields if they exist
      if ('title' in body) {
        existingTodo.title = String(body.title);
      }
      
      if ('description' in body) {
        existingTodo.description = String(body.description);
      }
      
      if ('completed' in body) {
        existingTodo.completed = Boolean(body.completed);
      }
      
      // Update timestamp
      existingTodo.updated_at = generateTimestamp();
      
      respondJSON(res, 200, existingTodo);
      return;
    }

    // Delete individual todo endpoint
    if (method === 'DELETE' && /^\/todos\/\d+$/.test(path)) {
      const id = path.split('/')[2];
      const todoIndex = todos.findIndex(t => t.id === parseInt(id) && t.userId === user.id);
      
      if (todoIndex === -1) {
        respondError(res, 404, 'Todo not found');
        return;
      }
      
      todos.splice(todoIndex, 1);
      
      res.writeHead(204);  // No content
      res.end();
      return;
    }

    // Default: endpoint not found
    respondError(res, 404, 'Not found');
  } catch (err) {
    // Handle parsing errors and other exceptions
    if (err instanceof SyntaxError) {
      respondError(res, 400, 'Invalid JSON');
    } else {
      console.error('Internal server error:', err);
      respondError(res, 500, 'Internal server error');
    }
  }
}

function startServer(port) {
  const server = http.createServer(handleRequest);
  
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server running on http://0.0.0.0:${port}`);
  });
  
  return server;
}

// Export for testing
module.exports = { startServer, handleRequest };

// Only start the server if this file is run directly
if (require.main === module) {
  const args = process.argv.slice(2);
  let port = 3000; // default
  
  // Parse CLI arguments
  for (let i = 0; i < args.length; i += 2) {
    if (args[i] === '--port' && args[i + 1]) {
      port = parseInt(args[i + 1]);
      break;
    }
  }
  
  startServer(port);
}