const http = require('http');
const url = require('url');
const crypto = require('crypto');
const querystring = require('querystring');

// In-memory storage
const users = new Map();
const todos = new Map();
const sessions = new Map(); // session_token -> user_id

// Global counters for auto-incrementing IDs
let userIdCounter = 1;
let todoIdCounter = 1;

// Helper function to generate tokens
function generateToken() {
  return crypto.randomBytes(16).toString('hex');
}

// Helper function to validate username
function isValidUsername(username) {
  if (!username) return false;
  if (username.length < 3 || username.length > 50) return false;
  return /^[a-zA-Z0-9_]+$/.test(username);
}

// Helper function to get cookie from request headers
function getCookieValue(cookieHeader, name) {
  if (!cookieHeader) return null;
  const cookies = cookieHeader.split('; ').reduce((acc, cookie) => {
    const [key, value] = cookie.split('=');
    acc[key] = value;
    return acc;
  }, {});
  return cookies[name] || null;
}

// Helper function to get current timestamp in ISO format (second precision)
function getCurrentTimestamp() {
  const now = new Date();
  return new Date(now.getTime() - (now.getTime() % 1000)).toISOString().replace(/\.\d{3}/, '');
}

// Middleware to authenticate requests
function authenticate(request) {
  const sessionToken = getCookieValue(request.headers.cookie, 'session_id');
  if (!sessionToken || !sessions.has(sessionToken)) {
    return { authenticated: false, userId: null };
  }
  return { authenticated: true, userId: sessions.get(sessionToken) };
}

// Helper function to send JSON response
function sendJsonResponse(response, statusCode, data) {
  response.writeHead(statusCode, {
    'Content-Type': 'application/json',
    ...(data === undefined ? {} : {})
  });
  
  if (data !== undefined && data !== null) {
    response.write(JSON.stringify(data));
  }
  response.end();
}

// Helper function to extract body from request
async function getBody(request) {
  let body = '';
  for await (const chunk of request) {
    body += chunk.toString();
  }
  return body;
}

// Main request handler
async function handleRequest(request, response) {
  const parsedUrl = url.parse(request.url, true);
  const pathname = parsedUrl.pathname;
  const method = request.method;

  try {
    // Routes
    if (method === 'POST' && pathname === '/register') {
      registerHandler(request, response);
    } else if (method === 'POST' && pathname === '/login') {
      await loginHandler(request, response);
    } else if (method === 'POST' && pathname === '/logout') {
      logoutHandler(request, response);
    } else if (method === 'GET' && pathname === '/me') {
      meHandler(request, response);
    } else if (method === 'PUT' && pathname === '/password') {
      await passwordHandler(request, response);
    } else if (method === 'GET' && pathname === '/todos') {
      todosGetHandler(request, response);
    } else if (method === 'POST' && pathname === '/todos') {
      await todosPostHandler(request, response);
    } else if (method === 'GET' && pathname.startsWith('/todos/')) {
      const todoId = parseInt(pathname.split('/')[2]);
      getTodoHandler(request, response, todoId);
    } else if (method === 'PUT' && pathname.startsWith('/todos/')) {
      const todoId = parseInt(pathname.split('/')[2]);
      await updateTodoHandler(request, response, todoId);
    } else if (method === 'DELETE' && pathname.startsWith('/todos/')) {
      const todoId = parseInt(pathname.split('/')[2]);
      deleteTodoHandler(request, response, todoId);
    } else {
      // Not found
      sendJsonResponse(response, 404, { error: 'Not Found' });
    }
  } catch (err) {
    console.error('Error handling request:', err);
    sendJsonResponse(response, 500, { error: 'Internal Server Error' });
  }
}

function registerHandler(request, response) {
  getBody(request).then(body => {
    try {
      const { username, password } = JSON.parse(body);

      if (!isValidUsername(username)) {
        return sendJsonResponse(response, 400, { error: 'Invalid username' });
      }

      if (!password || password.length < 8) {
        return sendJsonResponse(response, 400, { error: 'Password too short' });
      }

      // Check if username exists
      let isDuplicate = false;
      for (const [userId, userData] of users.entries()) {
        if (userData.username === username) {
          isDuplicate = true;
          break;
        }
      }

      if (isDuplicate) {
        return sendJsonResponse(response, 409, { error: 'Username already exists' });
      }

      // Create new user
      const user = {
        id: userIdCounter,
        username: username,
        password: password // In real applications, passwords should be hashed, but we'll store the raw password per spec
      };

      users.set(userIdCounter, user);
      userIdCounter++;

      // Return success without password
      delete user.password;
      sendJsonResponse(response, 201, user);
    } catch (e) {
      sendJsonResponse(response, 400, { error: 'Invalid JSON' });
    }
  }).catch(err => {
    sendJsonResponse(response, 500, { error: 'Server error reading request body' });
  });
}

async function loginHandler(request, response) {
  const body = await getBody(request);
  try {
    const { username, password } = JSON.parse(body);

    // Find user with matching username and password
    let foundUser = null;
    for (const [userId, userData] of users.entries()) {
      if (userData.username === username && userData.password === password) {
        foundUser = userData;
        break;
      }
    }

    if (!foundUser) {
      return sendJsonResponse(response, 401, { error: 'Invalid credentials' });
    }

    // Generate session token
    const sessionToken = generateToken();
    sessions.set(sessionToken, foundUser.id);

    // Set cookie and return user data
    response.writeHead(200, {
      'Content-Type': 'application/json',
      'Set-Cookie': `session_id=${sessionToken}; Path=/; HttpOnly`
    });

    const userResponse = { id: foundUser.id, username: foundUser.username };
    response.write(JSON.stringify(userResponse));
    response.end();
  } catch (e) {
    sendJsonResponse(response, 400, { error: 'Invalid JSON' });
  }
}

function logoutHandler(request, response) {
  const auth = authenticate(request);
  if (!auth.authenticated) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  // Remove session from memory
  const sessionToken = getCookieValue(request.headers.cookie, 'session_id');
  sessions.delete(sessionToken);

  sendJsonResponse(response, 200, {});
}

function meHandler(request, response) {
  const auth = authenticate(request);
  if (!auth.authenticated) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  const user = users.get(auth.userId);
  if (!user) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  const userResponse = { id: user.id, username: user.username };
  sendJsonResponse(response, 200, userResponse);
}

async function passwordHandler(request, response) {
  const auth = authenticate(request);
  if (!auth.authenticated) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  const body = await getBody(request);
  try {
    const { old_password, new_password } = JSON.parse(body);

    const user = users.get(auth.userId);
    if (!user || user.password !== old_password) {
      return sendJsonResponse(response, 401, { error: 'Invalid credentials' });
    }

    if (!new_password || new_password.length < 8) {
      return sendJsonResponse(response, 400, { error: 'Password too short' });
    }

    // Update password
    user.password = new_password;
    sendJsonResponse(response, 200, {});
  } catch (e) {
    sendJsonResponse(response, 400, { error: 'Invalid JSON' });
  }
}

function todosGetHandler(request, response) {
  const auth = authenticate(request);
  if (!auth.authenticated) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  // Get all todos for this user
  const userTodos = [];
  for (const [todoId, todoData] of todos.entries()) {
    if (todoData.userId === auth.userId) {
      // Send a copy of the todo data excluding the userId field
      const todoCopy = {...todoData};
      delete todoCopy.userId;
      userTodos.push(todoCopy);
    }
  }

  userTodos.sort((a, b) => a.id - b.id); // Sort by ID ascending
  sendJsonResponse(response, 200, userTodos);
}

async function todosPostHandler(request, response) {
  const auth = authenticate(request);
  if (!auth.authenticated) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  const body = await getBody(request);
  try {
    const { title, description = "" } = JSON.parse(body);

    if (!title || title.trim() === "") {
      return sendJsonResponse(response, 400, { error: 'Title is required' });
    }

    const createdAt = getCurrentTimestamp();
    
    const todo = {
      id: todoIdCounter,
      title: title.trim(),
      description: description,
      completed: false,
      created_at: createdAt,
      updated_at: createdAt
    };

    // Store the owner ID as well for security checks
    todo.userId = auth.userId;
    todos.set(todoIdCounter, todo);
    todoIdCounter++;

    // Don't return the userId field in the API response
    const todoResponse = {...todo};
    delete todoResponse.userId;
    sendJsonResponse(response, 201, todoResponse);
  } catch (e) {
    sendJsonResponse(response, 400, { error: 'Invalid JSON' });
  }
}

function getTodoHandler(request, response, todoId) {
  const auth = authenticate(request);
  if (!auth.authenticated) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  const todo = todos.get(todoId);
  if (!todo || todo.userId !== auth.userId) {
    return sendJsonResponse(response, 404, { error: 'Todo not found' });
  }

  // Don't include userId field in response
  const todoResponse = {...todo};
  delete todoResponse.userId;
  sendJsonResponse(response, 200, todoResponse);
}

async function updateTodoHandler(request, response, todoId) {
  const auth = authenticate(request);
  if (!auth.authenticated) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  const existingTodo = todos.get(todoId);
  if (!existingTodo || existingTodo.userId !== auth.userId) {
    return sendJsonResponse(response, 404, { error: 'Todo not found' });
  }

  const body = await getBody(request);
  try {
    const updates = JSON.parse(body);

    // Validation: if title is provided, it must not be empty
    if ('title' in updates && (!updates.title || updates.title.trim() === "")) {
      return sendJsonResponse(response, 400, { error: 'Title is required' });
    }

    // Update only provided fields
    existingTodo.updated_at = getCurrentTimestamp();
    
    if ('title' in updates) {
      existingTodo.title = updates.title.trim();
    }
    if ('description' in updates) {
      existingTodo.description = updates.description;
    }
    if ('completed' in updates) {
      existingTodo.completed = Boolean(updates.completed);
    }

    // Create response obj excluding userId
    const todoResponse = {...existingTodo};
    delete todoResponse.userId;
    sendJsonResponse(response, 200, todoResponse);
  } catch (e) {
    sendJsonResponse(response, 400, { error: 'Invalid JSON' });
  }
}

function deleteTodoHandler(request, response, todoId) {
  const auth = authenticate(request);
  if (!auth.authenticated) {
    return sendJsonResponse(response, 401, { error: 'Authentication required' });
  }

  const todo = todos.get(todoId);
  if (!todo || todo.userId !== auth.userId) {
    return sendJsonResponse(response, 404, { error: 'Todo not found' });
  }

  todos.delete(todoId);
  response.writeHead(204);
  response.end();
}

function startServer(port) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(handleRequest);
    server.listen(port, '0.0.0.0', () => {
      console.log(`Server running on 0.0.0.0:${port}`);
      resolve(server);
    });
  });
}

// Export the startServer function for testing purposes, or for use in the CLI handler below
module.exports = { startServer, handleRequest };

if (require.main === module) {
  // CLI handler
  const args = process.argv.slice(2);
  let port = 8080; // default port
  
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && args[i+1]) {
      port = parseInt(args[i+1], 10);
      i++; // Skip next argument since it's the port
    }
  }
  
  startServer(port).catch(console.error);
}