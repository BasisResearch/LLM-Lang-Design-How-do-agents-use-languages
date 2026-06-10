const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
let users = {};
let todos = {};
let sessions = {}; // session_id -> user_id mapping
let nextUserId = 1;
let nextTodoId = 1;

// Helper function to generate session IDs
function generateSessionId() {
  return crypto.randomBytes(32).toString('hex');
}

// Helper function to validate usernames
function isValidUsername(username) {
  return typeof username === 'string' && 
         username.length >= 3 && 
         username.length <= 50 && 
         /^[a-zA-Z0-9_]+$/.test(username);
}

// Helper function to validate password strength
function isValidPassword(password) {
  return typeof password === 'string' && password.length >= 8;
}

// Helper function to get current ISO timestamp with second precision
function getCurrentTimestamp() {
  const date = new Date();
  return date.toISOString().replace(/\.\d+Z$/, 'Z');
}

// Helper function to authenticate request using session ID
function authenticateRequest(req) {
  const cookies = parseCookies(req.headers.cookie || '');
  const sessionId = cookies.session_id;
  
  if (!sessionId || !sessions[sessionId]) {
    return null;
  }
  
  return sessions[sessionId]; // Returns user_id
}

// Parse cookies from header
function parseCookies(cookieHeader) {
  const cookies = {};
  if (cookieHeader) {
    const pairs = cookieHeader.split('; ');
    for (const pair of pairs) {
      const idx = pair.indexOf('=');
      if (idx > 0) {
        const key = pair.substring(0, idx);
        const value = pair.substring(idx + 1);
        cookies[key] = value;
      }
    }
  }
  return cookies;
}

// Server handler
function handleRequest(req, res) {
  const parsedUrl = url.parse(req.url, true);
  const path = parsedUrl.pathname;
  const method = req.method;
  
  // Handle DELETE separately since it has no response body
  if (method === 'DELETE' && /^\/todos\/\d+$/.test(path)) {
    // Don't set Content-Type header for DELETE responses
    handleDeleteTodoById(req, res, path);
    return;
  }
  
  // Set Content-Type header for non-DELETE responses
  res.setHeader('Content-Type', 'application/json');
  
  // Handle CORS preflight
  if (method === 'OPTIONS') {
    res.statusCode = 200;
    res.end();
    return;
  }

  // Routes
  if (method === 'POST' && path === '/register') {
    handleRegister(req, res);
  } else if (method === 'POST' && path === '/login') {
    handleLogin(req, res);
  } else if (method === 'POST' && path === '/logout') {
    handleLogout(req, res);
  } else if (method === 'GET' && path === '/me') {
    handleMe(req, res);
  } else if (method === 'PUT' && path === '/password') {
    handleChangePassword(req, res);
  } else if (method === 'GET' && path === '/todos') {
    handleGetTodos(req, res);
  } else if (method === 'POST' && path === '/todos') {
    handleCreateTodo(req, res);
  } else if (method === 'GET' && /^\/todos\/\d+$/.test(path)) {
    handleGetTodoById(req, res, path);
  } else if (method === 'PUT' && /^\/todos\/\d+$/.test(path)) {
    handleUpdateTodoById(req, res, path);
  } else {
    res.statusCode = 404;
    res.end(JSON.stringify({ error: 'Endpoint not found' }));
  }
}

// Register endpoint
function handleRegister(req, res) {
  let body = '';
  
  req.on('data', chunk => {
    body += chunk.toString();
  });
  
  req.on('end', () => {
    try {
      const { username, password } = JSON.parse(body);
      
      // Validate inputs
      if (!isValidUsername(username)) {
        res.statusCode = 400;
        res.end(JSON.stringify({ error: 'Invalid username' }));
        return;
      }
      
      if (!isValidPassword(password)) {
        res.statusCode = 400;
        res.end(JSON.stringify({ error: 'Password too short' }));
        return;
      }
      
      // Check if username exists
      for (const userId in users) {
        if (users[userId].username === username) {
          res.statusCode = 409;
          res.end(JSON.stringify({ error: 'Username already exists' }));
          return;
        }
      }
      
      // Create user
      const userId = nextUserId++;
      users[userId] = {
        id: userId,
        username,
        password: password // In real app we'd hash it
      };
      
      res.statusCode = 201;
      res.end(JSON.stringify({
        id: userId,
        username
      }));
    } catch (err) {
      res.statusCode = 400;
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });
}

// Login endpoint
function handleLogin(req, res) {
  let body = '';
  
  req.on('data', chunk => {
    body += chunk.toString();
  });
  
  req.on('end', () => {
    try {
      const { username, password } = JSON.parse(body);
      
      // Find user
      let foundUser = null;
      for (const userId in users) {
        if (users[userId].username === username) {
          if (users[userId].password === password) {
            foundUser = users[userId];
            break;
          }
        }
      }
      
      if (!foundUser) {
        res.statusCode = 401;
        res.end(JSON.stringify({ error: 'Invalid credentials' }));
        return;
      }
      
      // Generate session ID and store it server-side
      const sessionId = generateSessionId();
      sessions[sessionId] = foundUser.id; // Map session to user id
      
      // Set cookie and respond
      res.setHeader('Set-Cookie', `session_id=${sessionId}; Path=/; HttpOnly`);
      res.statusCode = 200;
      res.end(JSON.stringify({
        id: foundUser.id,
        username: foundUser.username
      }));
    } catch (err) {
      res.statusCode = 400;
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });
}

// Logout endpoint
function handleLogout(req, res) {
  // Authenticate
  const userId = authenticateRequest(req);
  if (!userId) {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  
  // Remove user's session(s)
  const cookies = parseCookies(req.headers.cookie || '');
  const sessionId = cookies.session_id;
  
  if (sessionId && sessions[sessionId]) {
    delete sessions[sessionId];
  }
  
  res.statusCode = 200;
  res.end(JSON.stringify({}));
}

// Me endpoint
function handleMe(req, res) {
  const userId = authenticateRequest(req);
  if (!userId) {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  
  const user = users[userId];
  res.statusCode = 200;
  res.end(JSON.stringify({
    id: user.id,
    username: user.username
  }));
}

// Change password endpoint
function handleChangePassword(req, res) {
  const userId = authenticateRequest(req);
  if (!userId) {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  
  let body = '';
  req.on('data', chunk => {
    body += chunk.toString();
  });
  
  req.on('end', () => {
    try {
      const { old_password, new_password } = JSON.parse(body);
      
      // Validate new password
      if (!isValidPassword(new_password)) {
        res.statusCode = 400;
        res.end(JSON.stringify({ error: 'Password too short' }));
        return;
      }
      
      // Check old password
      if (users[userId].password !== old_password) {
        res.statusCode = 401;
        res.end(JSON.stringify({ error: 'Invalid credentials' }));
        return;
      }
      
      // Update password
      users[userId].password = new_password;
      res.statusCode = 200;
      res.end(JSON.stringify({}));
    } catch (err) {
      res.statusCode = 400;
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });
}

// Get todos endpoint
function handleGetTodos(req, res) {
  const userId = authenticateRequest(req);
  if (!userId) {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  
  // Find todos for user
  const userTodos = [];
  for (const todoId in todos) {
    if (todos[todoId].user_id === userId) {
      userTodos.push(todos[todoId]);
    }
  }
  
  // Sort by ID ascending
  userTodos.sort((a, b) => a.id - b.id);
  
  res.statusCode = 200;
  res.end(JSON.stringify(userTodos));
}

// Create todo endpoint
function handleCreateTodo(req, res) {
  const userId = authenticateRequest(req);
  if (!userId) {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  
  let body = '';
  req.on('data', chunk => {
    body += chunk.toString();
  });
  
  req.on('end', () => {
    try {
      const { title, description } = JSON.parse(body);
      
      // Validate title
      if (!title || typeof title !== 'string' || title.trim() === '') {
        res.statusCode = 400;
        res.end(JSON.stringify({ error: 'Title is required' }));
        return;
      }
      
      // Create todo
      const todoId = nextTodoId++;
      const now = getCurrentTimestamp();
      
      const newTodo = {
        id: todoId,
        title,
        description: description || "",
        completed: false,
        created_at: now,
        updated_at: now,
        user_id: userId
      };
      
      todos[todoId] = newTodo;
      
      res.statusCode = 201;
      res.end(JSON.stringify(newTodo));
    } catch (err) {
      res.statusCode = 400;
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });
}

// Get todo by ID endpoint
function handleGetTodoById(req, res, path) {
  const userId = authenticateRequest(req);
  if (!userId) {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  
  // Extract ID from path
  const id = parseInt(path.split('/')[2], 10);
  
  if (!todos[id] || todos[id].user_id !== userId) {
    res.statusCode = 404;
    res.end(JSON.stringify({ error: 'Todo not found' }));
    return;
  }
  
  res.statusCode = 200;
  res.end(JSON.stringify(todos[id]));
}

// Update todo by ID endpoint (partial update)
function handleUpdateTodoById(req, res, path) {
  const userId = authenticateRequest(req);
  if (!userId) {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  
  // Extract ID from path
  const id = parseInt(path.split('/')[2], 10);
  
  if (!todos[id] || todos[id].user_id !== userId) {
    res.statusCode = 404;
    res.end(JSON.stringify({ error: 'Todo not found' }));
    return;
  }
  
  let body = '';
  req.on('data', chunk => {
    body += chunk.toString();
  });
  
  req.on('end', () => {
    try {
      const updateData = JSON.parse(body);
      const todo = todos[id];
      const now = getCurrentTimestamp();
      
      // Validate title if provided
      if (updateData.hasOwnProperty('title')) {
        if (!updateData.title || typeof updateData.title !== 'string' || updateData.title.trim() === '') {
          res.statusCode = 400;
          res.end(JSON.stringify({ error: 'Title is required' }));
          return;
        }
        todo.title = updateData.title;
      }
      
      // Update other fields if provided
      if (updateData.hasOwnProperty('description')) {
        todo.description = updateData.description;
      }
      
      if (updateData.hasOwnProperty('completed')) {
        todo.completed = Boolean(updateData.completed);
      }
      
      // Update timestamp
      todo.updated_at = now;
      
      res.statusCode = 200;
      res.end(JSON.stringify(todo));
    } catch (err) {
      res.statusCode = 400;
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });
}

// Delete todo by ID endpoint
function handleDeleteTodoById(req, res, path) {
  const userId = authenticateRequest(req);
  if (!userId) {
    res.statusCode = 401;
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }
  
  // Extract ID from path
  const id = parseInt(path.split('/')[2], 10);
  
  if (!todos[id] || todos[id].user_id !== userId) {
    res.statusCode = 404;
    res.end(JSON.stringify({ error: 'Todo not found' }));
    return;
  }
  
  delete todos[id];
  
  // 204 No Content - no body and no Content-Type header
  res.statusCode = 204;
  res.end(); // no body
}

// Create and run server
function createServer(port) {
  const server = http.createServer(handleRequest);
  
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server running on http://0.0.0.0:${port}`);
  });
  
  return server;
}

module.exports = { createServer };

// For direct execution
if (require.main === module) {
  const args = process.argv.slice(2);
  let port = 3000; // default
  
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && args[i + 1]) {
      port = parseInt(args[i + 1], 10);
      i++; // Skip the next argument
    }
  }
  
  createServer(port);
}