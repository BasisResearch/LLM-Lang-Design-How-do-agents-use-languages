const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
let users = [];
let todos = [];
let sessions = new Map(); // session_id -> user_id

// Auto-incrementing IDs
let nextUserId = 1;
let nextTodoId = 1;

// Helper functions
function generateSessionId() {
  return crypto.randomBytes(16).toString('hex');
}

function getCurrentIsoTimestamp() {
  const date = new Date();
  // Round down to nearest second
  date.setMilliseconds(0);
  return date.toISOString().slice(0, 19) + 'Z';
}

function getUserById(userId) {
  return users.find(user => user.id === userId);
}

function getTodoById(todoId) {
  return todos.find(todo => todo.id === todoId);
}

function getUsernameValidator(username) {
  return /^[a-zA-Z0-9_]+$/.test(username) && username.length >= 3 && username.length <= 50;
}

function getPasswordValidator(password) {
  return password.length >= 8;
}

function validateToken(sessionId) {
  return sessions.has(sessionId);
}

function getUserIdFromToken(sessionId) {
  return sessions.get(sessionId);
}

function sendResponse(res, statusCode, data) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  if (data !== undefined) {
    res.end(JSON.stringify(data));
  } else {
    res.end();
  }
}

function sendError(res, statusCode, message) {
  sendResponse(res, statusCode, { error: message });
}

function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  
  cookieHeader.split(';').forEach(cookie => {
    const [key, value] = cookie.trim().split('=');
    if (key && value) {
      cookies[key] = value;
    }
  });
  return cookies;
}

// Find the authenticated user ID from session token in request headers
function getAuthenticatedUserId(req) {
  const cookies = parseCookies(req.headers.cookie);
  const sessionId = cookies.session_id;
  
  if (!sessionId || !sessions.has(sessionId)) {
    return null;
  }
  
  return sessions.get(sessionId);
}

// Authentication middleware
function requireAuth(req, res) {
  const userId = getAuthenticatedUserId(req);
  if (!userId) {
    sendError(res, 401, 'Authentication required');
    return null;
  }
  return userId;
}

// Request body parser
function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk.toString();
    });
    req.on('end', () => {
      try {
        const parsed = body ? JSON.parse(body) : {};
        resolve(parsed);
      } catch (e) {
        reject(new Error('Invalid JSON'));
      }
    });
  });
}

// Main request handler
function handleRequest(req, res) {
  const parsedUrl = url.parse(req.url, true);
  const method = req.method;
  const pathname = parsedUrl.pathname;

  // Routes
  try {
    if (method === 'POST' && pathname === '/register') {
      return handleRegister(req, res);
    } else if (method === 'POST' && pathname === '/login') {
      return handleLogin(req, res);
    } else if (method === 'POST' && pathname === '/logout') {
      return handleLogout(req, res);
    } else if (method === 'GET' && pathname === '/me') {
      return handleMe(req, res);
    } else if (method === 'PUT' && pathname === '/password') {
      return handlePassword(req, res);
    } else if (method === 'GET' && pathname === '/todos') {
      return handleGetTodos(req, res);
    } else if (method === 'POST' && pathname === '/todos') {
      return handleCreateTodo(req, res);
    } else if (pathname.startsWith('/todos/') && method === 'GET') {
      const todoId = parseInt(pathname.split('/')[2]);
      return handleGetTodo(req, res, todoId);
    } else if (pathname.startsWith('/todos/') && method === 'PUT') {
      const todoId = parseInt(pathname.split('/')[2]);
      return handleUpdateTodo(req, res, todoId);
    } else if (pathname.startsWith('/todos/') && method === 'DELETE') {
      const todoId = parseInt(pathname.split('/')[2]);
      return handleDeleteTodo(req, res, todoId);
    } else {
      sendError(res, 404, 'Not found');
    }
  } catch (e) {
    console.error('Error handling request:', e);
    sendError(res, 500, 'Internal server error');
  }
}

async function handleRegister(req, res) {
  try {
    const body = await parseBody(req);
    
    const { username, password } = body;
    
    // Validate username
    if (!username) {
      return sendError(res, 400, 'Invalid username');
    }
    
    if (!getUsernameValidator(username)) {
      return sendError(res, 400, 'Invalid username');
    }
    
    // Validate password
    if (!password) {
      return sendError(res, 400, 'Password too short');
    }
    
    if (!getPasswordValidator(password)) {
      return sendError(res, 400, 'Password too short');
    }
    
    // Check if username is taken
    if (users.some(u => u.username === username)) {
      return sendError(res, 409, 'Username already exists');
    }
    
    // Create user
    const newUser = {
      id: nextUserId++,
      username,
      password: password // In real app, hash the password!
    };
    
    users.push(newUser);
    // Remove password before sending response
    const responseUser = { id: newUser.id, username: newUser.username };
    sendResponse(res, 201, responseUser);
  } catch (e) {
    if (e.message === 'Invalid JSON') {
      sendError(res, 400, 'Invalid JSON');
    } else {
      console.error('Registration error:', e);
      sendError(res, 500, 'Internal server error');
    }
  }
}

async function handleLogin(req, res) {
  try {
    const body = await parseBody(req);
    
    const { username, password } = body;
    
    const user = users.find(u => u.username === username && u.password === password);
    
    if (!user) {
      return sendError(res, 401, 'Invalid credentials');
    }
    
    // Generate session
    const sessionId = generateSessionId();
    sessions.set(sessionId, user.id);
    
    // Set cookie and respond
    res.setHeader('Set-Cookie', `session_id=${sessionId}; Path=/; HttpOnly`);
    const responseUser = { id: user.id, username: user.username };
    sendResponse(res, 200, responseUser);
  } catch (e) {
    if (e.message === 'Invalid JSON') {
      sendError(res, 400, 'Invalid JSON');
    } else {
      console.error('Login error:', e);
      sendError(res, 500, 'Internal server error');
    }
  }
}

async function handleLogout(req, res) {
  const userId = requireAuth(req, res);
  if (userId === null) return; // Error response already sent by requireAuth
  
  try {
    const cookies = parseCookies(req.headers.cookie);
    const sessionId = cookies.session_id;
    
    if (sessionId && sessions.has(sessionId)) {
      sessions.delete(sessionId); // Invalidate session server-side
    }
    
    sendResponse(res, 200, {});
  } catch (e) {
    console.error('Logout error:', e);
    sendError(res, 500, 'Internal server error');
  }
}

function handleMe(req, res) {
  const userId = requireAuth(req, res);
  if (userId === null) return; // Error response already sent by requireAuth
  
  try {
    const user = getUserById(userId);
    if (!user) {
      return sendError(res, 401, 'Authentication required');
    }
    
    const responseUser = { id: user.id, username: user.username };
    sendResponse(res, 200, responseUser);
  } catch (e) {
    console.error('Me error:', e);
    sendError(res, 500, 'Internal server error');
  }
}

async function handlePassword(req, res) {
  const userId = requireAuth(req, res);
  if (userId === null) return; // Error response already sent by requireAuth
  
  try {
    const body = await parseBody(req);
    
    const { old_password, new_password } = body;
    
    const user = getUserById(userId);
    if (!user || user.password !== old_password) {
      return sendError(res, 401, 'Invalid credentials');
    }
    
    if (!new_password || !getPasswordValidator(new_password)) {
      return sendError(res, 400, 'Password too short');
    }
    
    user.password = new_password;
    sendResponse(res, 200, {});
  } catch (e) {
    if (e.message === 'Invalid JSON') {
      sendError(res, 400, 'Invalid JSON');
    } else {
      console.error('Password change error:', e);
      sendError(res, 500, 'Internal server error');
    }
  }
}

function handleGetTodos(req, res) {
  const userId = requireAuth(req, res);
  if (userId === null) return; // Error response already sent by requireAuth
  
  try {
    // Filter todos for current user only
    const userTodos = todos.filter(todo => todo.userId === userId).sort((a, b) => a.id - b.id);
    sendResponse(res, 200, userTodos);
  } catch (e) {
    console.error('Get todos error:', e);
    sendError(res, 500, 'Internal server error');
  }
}

async function handleCreateTodo(req, res) {
  const userId = requireAuth(req, res);
  if (userId === null) return; // Error response already sent by requireAuth
  
  try {
    const body = await parseBody(req);
    
    const { title, description } = body;
    
    if (!title || title.trim() === '') {
      return sendError(res, 400, 'Title is required');
    }
    
    const createdAt = getCurrentIsoTimestamp();
    const newTodo = {
      id: nextTodoId++,
      title: title.trim(),
      description: description || '',
      completed: false,
      created_at: createdAt,
      updated_at: createdAt,
      userId // Associate with user who created it
    };
    
    todos.push(newTodo);
    sendResponse(res, 201, newTodo);
  } catch (e) {
    if (e.message === 'Invalid JSON') {
      sendError(res, 400, 'Invalid JSON');
    } else {
      console.error('Create todo error:', e);
      sendError(res, 500, 'Internal server error');
    }
  }
}

function handleGetTodo(req, res, todoId) {
  const userId = requireAuth(req, res);
  if (userId === null) return; // Error response already sent by requireAuth
  
  try {
    const todo = getTodoById(todoId);
    
    // Check if todo exists and belongs to current user
    if (!todo || todo.userId !== userId) {
      return sendError(res, 404, 'Todo not found');
    }
    
    sendResponse(res, 200, todo);
  } catch (e) {
    console.error('Get todo error:', e);
    sendError(res, 500, 'Internal server error');
  }
}

async function handleUpdateTodo(req, res, todoId) {
  const userId = requireAuth(req, res);
  if (userId === null) return; // Error response already sent by requireAuth
  
  try {
    const body = await parseBody(req);
    const todo = getTodoById(todoId);
    
    // Check if todo exists and belongs to current user
    if (!todo || todo.userId !== userId) {
      return sendError(res, 404, 'Todo not found');
    }
    
    // Validate title if provided
    if (body.title !== undefined && body.title.trim() === '') {
      return sendError(res, 400, 'Title is required');
    }
    
    // Update fields
    if (body.title !== undefined) {
      todo.title = body.title.trim();
    }
    if (body.description !== undefined) {
      todo.description = body.description;
    }
    if (body.completed !== undefined) {
      todo.completed = Boolean(body.completed);
    }
    
    // Update the timestamp
    todo.updated_at = getCurrentIsoTimestamp();
    
    sendResponse(res, 200, todo);
  } catch (e) {
    if (e.message === 'Invalid JSON') {
      sendError(res, 400, 'Invalid JSON');
    } else {
      console.error('Update todo error:', e);
      sendError(res, 500, 'Internal server error');
    }
  }
}

function handleDeleteTodo(req, res, todoId) {
  const userId = requireAuth(req, res);
  if (userId === null) return; // Error response already sent by requireAuth
  
  try {
    const todoIndex = todos.findIndex(todo => todo.id === todoId && todo.userId === userId);
    
    if (todoIndex === -1) {
      return sendError(res, 404, 'Todo not found');
    }
    
    todos.splice(todoIndex, 1);
    res.writeHead(204); // No Content - don't include a body
    res.end();
  } catch (e) {
    console.error('Delete todo error:', e);
    sendError(res, 500, 'Internal server error');
  }
}

// Parse command line arguments to get port
let port = 3000; // default
for (let i = 0; i < process.argv.length; i++) {
  if (process.argv[i] === '--port' && process.argv[i + 1]) {
    port = parseInt(process.argv[i + 1]);
    break;
  }
}

// Create and start the server
const server = http.createServer(handleRequest);
server.listen(port, '0.0.0.0', () => {
  console.log(`Todo App server running on http://0.0.0.0:${port}`);
});