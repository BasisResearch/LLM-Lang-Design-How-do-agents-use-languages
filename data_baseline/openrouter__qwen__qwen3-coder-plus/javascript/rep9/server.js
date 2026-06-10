const http = require('http');
const url = require('url');
const crypto = require('crypto');

// In-memory storage
let users = {};
let todos = {};
let userCounter = 0;
let todoCounter = 0;

// Session management (in-memory)
const sessions = {};

// Helper to generate session ID
function generateSessionId() {
  return crypto.randomBytes(32).toString('hex');
}

// Helper to validate username
function validateUsername(username) {
  if (!username || typeof username !== 'string') return false;
  const regex = /^[a-zA-Z0-9_]+$/;
  return username.length >= 3 && username.length <= 50 && regex.test(username);
}

// Helper to validate password
function validatePassword(password) {
  return password && password.length >= 8;
}

// Get date in ISO 8601 format with second precision
function getISOTime() {
  const date = new Date();
  // Round down to seconds
  const roundedDate = new Date(Math.floor(date.getTime() / 1000) * 1000);
  return roundedDate.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// Main request handler
function handleRequest(request, response) {
  const parsedUrl = url.parse(request.url, true);
  const path = parsedUrl.pathname;
  const method = request.method;

  // CORS and content-type headers
  response.setHeader('Content-Type', 'application/json');

  // Parse the request body
  let body = '';
  request.on('data', chunk => {
    body += chunk.toString();
  });

  request.on('end', () => {
    try {
      // Default response if route not found
      if (!routeHandler(path, method, body, request, response)) {
        response.statusCode = 404;
        response.end(JSON.stringify({ error: 'Not found' }));
      }
    } catch (err) {
      console.error('Error handling request:', err);
      response.statusCode = 500;
      response.end(JSON.stringify({ error: 'Internal server error' }));
    }
  });
}

// Route dispatcher
function routeHandler(path, method, body, request, response) {
  // Extract session ID from cookies
  const cookieHeader = request.headers.cookie;
  let sessionId = null;
  if (cookieHeader) {
    const cookies = cookieHeader.split(';').map(cookie => cookie.trim());
    for (const cookie of cookies) {
      if (cookie.startsWith('session_id=')) {
        sessionId = cookie.substring(11); // 'session_id='.length
        break;
      }
    }
  }

  // Check if the request needs authentication
  const requiresAuth = [
    '/me',
    '/password',
    '/todos',
    '/logout'
  ].some(authPath => {
    return path.startsWith(authPath) || 
           (path.startsWith('/todos/') && authPath === '/todos'); // Handle /todos/:id routes
  });

  // Verify the session is valid (if authentication needed)
  let currentUser = null;
  if (requiresAuth) {
    if (!sessionId || !sessions[sessionId]) {
      response.statusCode = 401;
      response.end(JSON.stringify({ error: "Authentication required" }));
      return true;
    }
    currentUser = sessions[sessionId];
    if (!currentUser) {
      response.statusCode = 401;
      response.end(JSON.stringify({ error: "Authentication required" }));
      return true;
    }
  }

  // Routes
  if (method === 'POST' && path === '/register') {
    registerUser(body, response);
    return true;
  } else if (method === 'POST' && path === '/login') {
    loginUser(body, response);
    return true;
  } else if (method === 'POST' && path === '/logout') {
    logoutUser(sessionId, response);
    return true;
  } else if (method === 'GET' && path === '/me') {
    getUserInfo(currentUser, response);
    return true;
  } else if (method === 'PUT' && path === '/password') {
    changePassword(body, currentUser, response);
    return true;
  } else if (method === 'GET' && path === '/todos') {
    getTodos(currentUser, response);
    return true;
  } else if (method === 'POST' && path === '/todos') {
    createTodo(body, currentUser, response);
    return true;
  } else if (path.startsWith('/todos/')) {
    // Extract ID from path like /todos/123
    const parts = path.split('/');
    if (parts.length === 3 && parts[1] === 'todos') {
      const todoId = parseInt(parts[2]);
      if (isNaN(todoId)) {
        response.statusCode = 404;
        response.end(JSON.stringify({ error: "Todo not found" }));
        return true;
      }

      if (method === 'GET') {
        getTodo(todoId, currentUser, response);
        return true;
      } else if (method === 'PUT') {
        updateTodo(todoId, body, currentUser, response);
        return true;
      } else if (method === 'DELETE') {
        deleteTodo(todoId, currentUser, response);
        return true;
      }
    }
  }

  return false; // Route not handled
}

// Register a new user
function registerUser(requestBody, response) {
  try {
    const data = JSON.parse(requestBody);
    
    // Validation
    if (!validateUsername(data.username)) {
      response.statusCode = 400;
      response.end(JSON.stringify({ error: "Invalid username" }));
      return;
    }
    
    if (!validatePassword(data.password)) {
      response.statusCode = 400;
      response.end(JSON.stringify({ error: "Password too short" }));
      return;
    }
    
    // Check if username exists
    let existingUserId = null;
    for (const userId in users) {
      if (users[userId].username === data.username) {
        existingUserId = userId;
        break;
      }
    }
    
    if (existingUserId !== null) {
      response.statusCode = 409;
      response.end(JSON.stringify({ error: "Username already exists" }));
      return;
    }
    
    // Create user
    userCounter++;
    const user = {
      id: userCounter,
      username: data.username,
      password: data.password  // In a real app, we'd hash the password
    };
    
    users[user.id] = user;
    
    response.statusCode = 201;
    response.end(JSON.stringify({
      id: user.id,
      username: user.username
    }));
  } catch (e) {
    response.statusCode = 400;
    response.end(JSON.stringify({ error: "Invalid JSON in request body" }));
  }
}

// Login user
function loginUser(requestBody, response) {
  try {
    const data = JSON.parse(requestBody);
    let userId = null;
    
    // Find user by username
    for (const id in users) {
      if (users[id].username === data.username) {
        userId = parseInt(id);
        break;
      }
    }
    
    // Validate password
    if (!userId || users[userId].password !== data.password) {
      response.statusCode = 401;
      response.end(JSON.stringify({ error: "Invalid credentials" }));
      return;
    }
    
    // Generate session ID
    const sessionId = generateSessionId();
    
    // Store session
    sessions[sessionId] = { id: userId, username: data.username };
    
    // Set cookie header
    response.setHeader('Set-Cookie', `session_id=${sessionId}; Path=/; HttpOnly`);
    
    response.statusCode = 200;
    response.end(JSON.stringify({
      id: userId,
      username: data.username
    }));
  } catch (e) {
    response.statusCode = 400;
    response.end(JSON.stringify({ error: "Invalid JSON in request body" }));
  }
}

// Logout user
function logoutUser(sessionId, response) {
  if (sessionId && sessions[sessionId]) {
    delete sessions[sessionId];
  }
  
  response.statusCode = 200;
  response.end(JSON.stringify({}));
}

// Get user info
function getUserInfo(user, response) {
  response.statusCode = 200;
  response.end(JSON.stringify({
    id: user.id,
    username: user.username
  }));
}

// Change password
function changePassword(requestBody, currentUser, response) {
  try {
    const data = JSON.parse(requestBody);
    
    if (users[currentUser.id].password !== data.old_password) {
      response.statusCode = 401;
      response.end(JSON.stringify({ error: "Invalid credentials" }));
      return;
    }
    
    if (!validatePassword(data.new_password)) {
      response.statusCode = 400;
      response.end(JSON.stringify({ error: "Password too short" }));
      return;
    }
    
    // Update password
    users[currentUser.id].password = data.new_password;
    
    response.statusCode = 200;
    response.end(JSON.stringify({}));
  } catch (e) {
    response.statusCode = 400;
    response.end(JSON.stringify({ error: "Invalid JSON in request body" }));
  }
}

// Get all todos for a user
function getTodos(currentUser, response) {
  // Filter todos that belong to current user
  const userTodos = [];
  for (const id in todos) {
    if (todos[id].userId === currentUser.id) {
      userTodos.push(todos[id]);
    }
  }
  
  // Sort by ID ascending
  userTodos.sort((a, b) => a.id - b.id);
  
  response.statusCode = 200;
  response.end(JSON.stringify(userTodos));
}

// Create a new todo
function createTodo(requestBody, currentUser, response) {
  try {
    const data = JSON.parse(requestBody);
    
    // Validate title
    if (!data.title || data.title.trim() === "") {
      response.statusCode = 400;
      response.end(JSON.stringify({ error: "Title is required" }));
      return;
    }
    
    // Create todo
    todoCounter++;
    const now = getISOTime();
    const todo = {
      id: todoCounter,
      userId: currentUser.id,  // Associate todo with user
      title: data.title,
      description: data.description || "",
      completed: false,
      created_at: now,
      updated_at: now
    };
    
    todos[todo.id] = todo;
    
    response.statusCode = 201;
    response.end(JSON.stringify(todo));
  } catch (e) {
    response.statusCode = 400;
    response.end(JSON.stringify({ error: "Invalid JSON in request body" }));
  }
}

// Get a specific todo
function getTodo(todoId, currentUser, response) {
  if (!todos[todoId] || todos[todoId].userId !== currentUser.id) {
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "Todo not found" }));
    return;
  }
  
  response.statusCode = 200;
  response.end(JSON.stringify(todos[todoId]));
}

// Update a specific todo
function updateTodo(todoId, requestBody, currentUser, response) {
  if (!todos[todoId] || todos[todoId].userId !== currentUser.id) {
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "Todo not found" }));
    return;
  }
  
  try {
    const data = JSON.parse(requestBody);
    
    // Validate title if present
    if (data.title !== undefined && data.title.trim() === "") {
      response.statusCode = 400;
      response.end(JSON.stringify({ error: "Title is required" }));
      return;
    }
    
    // Update todo with provided values
    if (data.title !== undefined) {
      todos[todoId].title = data.title;
    }
    if (data.description !== undefined) {
      todos[todoId].description = data.description;
    }
    if (data.completed !== undefined) {
      todos[todoId].completed = data.completed;
    }
   
    // Update timestamp
    todos[todoId].updated_at = getISOTime();
    
    response.statusCode = 200;
    response.end(JSON.stringify(todos[todoId]));
  } catch (e) {
    response.statusCode = 400;
    response.end(JSON.stringify({ error: "Invalid JSON in request body" }));
  }
}

// Delete a specific todo
function deleteTodo(todoId, currentUser, response) {
  if (!todos[todoId] || todos[todoId].userId !== currentUser.id) {
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "Todo not found" }));
    return;
  }
  
  delete todos[todoId];
  response.statusCode = 204;
  response.end(); // No body for 204
}

// Start server function
function startServer(port) {
  const server = http.createServer(handleRequest);
  
  server.listen(port, '0.0.0.0', () => {
    console.log(`Server is running on http://0.0.0.0:${port}`);
  });
}

// Extract command line arguments
const args = process.argv.slice(2);
let port = 3000; // Default port

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && i + 1 < args.length) {
    port = parseInt(args[i + 1]);
    i++; // Skip next argument
  }
}

startServer(port);