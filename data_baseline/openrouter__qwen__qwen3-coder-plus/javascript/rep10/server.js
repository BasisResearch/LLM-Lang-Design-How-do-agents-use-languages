const http = require('http');
const url = require('url');
const { v4: uuidv4 } = require('uuid');
const bcrypt = require('bcryptjs');

// In-memory storage
let users = [];
let todos = [];
let sessions = {}; // Maps session_id -> user_id

// Auto-incrementing IDs
let nextUserId = 1;
let nextTodoId = 1;

class UserManager {
  static createUser(username, password) {
    const hashedPassword = bcrypt.hashSync(password, 10);
    const user = {
      id: nextUserId++,
      username: username,
      password: hashedPassword // Store the hashed password
    };
    
    users.push(user);
    return { id: user.id, username: user.username };
  }

  static findUserByUsername(username) {
    return users.find(u => u.username === username);
  }

  static getUserById(userId) {
    return users.find(u => u.id === userId);
  }

  static authenticateUser(username, password) {
    const user = UserManager.findUserByUsername(username);
    if (!user) return null;
    if (!bcrypt.compareSync(password, user.password)) return null;
    return { id: user.id, username: user.username };
  }

  static updatePassword(userId, oldPassword, newPassword) {
    const userIndex = users.findIndex(u => u.id === userId);
    if (userIndex === -1) return false;

    const user = users[userIndex];
    if (!bcrypt.compareSync(oldPassword, user.password)) return false;

    users[userIndex].password = bcrypt.hashSync(newPassword, 10);
    return true;
  }
}

class TodoManager {
  static createTodo(userId, title, description = "") {
    const now = new Date();
    const formattedTime = now.toISOString().replace(/\.\d{3}/, '');
    
    const todo = {
      id: nextTodoId++,
      title,
      description,
      completed: false,
      created_at: formattedTime,
      updated_at: formattedTime,
      user_id: userId
    };
    
    todos.push(todo);
    return { ...todo };
  }

  static getTodosByUserId(userId) {
    return todos.filter(t => t.user_id === userId);
  }

  static getTodoByIdAndUserId(todoId, userId) {
    return todos.find(t => t.id === todoId && t.user_id === userId);
  }

  static updateTodo(todoId, userId, updates) {
    const todoIndex = todos.findIndex(t => t.id === todoId && t.user_id === userId);
    if (todoIndex === -1) return null;

    const now = new Date();
    const formattedTime = now.toISOString().replace(/\.\d{3}/, '');

    // Apply updates
    if (updates.title !== undefined) {
      todos[todoIndex].title = updates.title;
    }
    if (updates.description !== undefined) {
      todos[todoIndex].description = updates.description;
    }
    if (updates.completed !== undefined) {
      todos[todoIndex].completed = updates.completed;
    }
    todos[todoIndex].updated_at = formattedTime;

    return { ...todos[todoIndex] };
  }

  static deleteTodo(todoId, userId) {
    const initialLength = todos.length;
    todos = todos.filter(t => !(t.id === todoId && t.user_id === userId));
    return todos.length < initialLength; // Returns true if a todo was deleted
  }
}

class AuthManager {
  static generateSession() {
    const sessionId = uuidv4();
    // No expiration for simplicity, but in production you'd want this
    return sessionId;
  }

  static validateSession(sessionId) {
    const userId = sessions[sessionId];
    return userId ? UserManager.getUserById(userId) : null;
  }

  static createSession(userId) {
    const sessionId = AuthManager.generateSession();
    sessions[sessionId] = userId;
    return sessionId;
  }

  static destroySession(sessionId) {
    delete sessions[sessionId];
  }
}

function parseCookies(request) {
  const cookies = {};
  if (request.headers.cookie) {
    const cookieString = request.headers.cookie;
    cookieString.split(';').forEach(cookie => {
      const parts = cookie.trim().split('=');
      if (parts.length === 2) {
        cookies[parts[0]] = parts[1];
      }
    });
  }
  return cookies;
}

function parseRequestBody(request) {
  return new Promise((resolve, reject) => {
    let body = '';
    request.on('data', chunk => {
      body += chunk.toString();
    });
    request.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (err) {
        reject(err);
      }
    });
  });
}

function sendResponse(response, statusCode, data = null, headers = {}) {
  response.statusCode = statusCode;
  
  // Add Content-Type header except for DELETE which has no body
  if (statusCode !== 204) {
    headers['Content-Type'] = 'application/json';
  }
  
  Object.keys(headers).forEach(header => {
    response.setHeader(header, headers[header]);
  });

  if (data !== null) {
    response.write(JSON.stringify(data));
  }
  
  response.end();
}

function validateUsername(username) {
  if (typeof username !== 'string') {
    return false;
  }
  if (username.length < 3 || username.length > 50) {
    return false;
  }
  const regex = /^[a-zA-Z0-9_]+$/;
  return regex.test(username);
}

function handleRequest(request, response) {
  const parsedUrl = url.parse(request.url, true);
  const path = parsedUrl.pathname;
  const method = request.method;

  // Extract session from cookies
  const cookies = parseCookies(request);
  const sessionId = cookies.session_id;

  // Check if endpoint requires authentication
  const protectedEndpoints = [
    '/me',
    '/password',
    '/todos',
    '/todos/'
  ];

  const isProtected = protectedEndpoints.some(endpoint => 
    path.startsWith(endpoint) || 
    path === '/logout'
  );

  let currentUser = null;
  if (isProtected || method !== 'POST' || !['/register', '/login'].includes(path)) {
    if (sessionId) {
      const userId = sessions[sessionId];
      if (userId) {
        const user = UserManager.getUserById(userId);
        if (user) {
          currentUser = { id: user.id, username: user.username };
        }
      }
    }
  }

  if (isProtected && !currentUser) {
    sendResponse(response, 401, { error: "Authentication required" });
    return;
  }

  // Route handling
  if (method === 'POST' && path === '/register') {
    parseRequestBody(request)
      .then(body => {
        const { username, password } = body;
        
        if (typeof username !== 'string') {
          sendResponse(response, 400, { error: "Invalid username" });
          return;
        }
        
        if (!validateUsername(username)) {
          sendResponse(response, 400, { error: "Invalid username" });
          return;
        }
        
        if (!password || typeof password !== 'string' || password.length < 8) {
          sendResponse(response, 400, { error: "Password too short" });
          return;
        }
        
        if (UserManager.findUserByUsername(username)) {
          sendResponse(response, 409, { error: "Username already exists" });
          return;
        }
        
        const newUser = UserManager.createUser(username, password);
        sendResponse(response, 201, newUser);
      })
      .catch(() => {
        sendResponse(response, 400, { error: "Invalid request body" });
      });
  } else if (method === 'POST' && path === '/login') {
    parseRequestBody(request)
      .then(body => {
        const { username, password } = body;
        
        const authenticatedUser = UserManager.authenticateUser(username, password);
        if (!authenticatedUser) {
          sendResponse(response, 401, { error: "Invalid credentials" });
          return;
        }
        
        const sessionId = AuthManager.createSession(authenticatedUser.id);
        response.setHeader('Set-Cookie', `session_id=${sessionId}; Path=/; HttpOnly`);
        
        sendResponse(response, 200, authenticatedUser);
      })
      .catch(() => {
        sendResponse(response, 400, { error: "Invalid request body" });
      });
  } else if (method === 'POST' && path === '/logout') {
    if (!sessionId) {
      sendResponse(response, 401, { error: "Authentication required" });
      return;
    }
    
    AuthManager.destroySession(sessionId);
    sendResponse(response, 200, {});
  } else if (method === 'GET' && path === '/me') {
    sendResponse(response, 200, currentUser);
  } else if (method === 'PUT' && path === '/password') {
    parseRequestBody(request)
      .then(body => {
        const { old_password, new_password } = body;
        
        if (typeof new_password !== 'string' || new_password.length < 8) {
          sendResponse(response, 400, { error: "Password too short" });
          return;
        }
        
        const success = UserManager.updatePassword(currentUser.id, old_password, new_password);
        if (!success) {
          sendResponse(response, 401, { error: "Invalid credentials" });
          return;
        }
        
        sendResponse(response, 200, {});
      })
      .catch(() => {
        sendResponse(response, 400, { error: "Invalid request body" });
      });
  } else if (method === 'GET' && path === '/todos') {
    const userTodos = TodoManager.getTodosByUserId(currentUser.id);
    sendResponse(response, 200, userTodos);
  } else if (method === 'POST' && path === '/todos') {
    parseRequestBody(request)
      .then(body => {
        const { title, description = "" } = body;
        
        if (!title || title.trim() === '') {
          sendResponse(response, 400, { error: "Title is required" });
          return;
        }
        
        const newTodo = TodoManager.createTodo(currentUser.id, title, description);
        sendResponse(response, 201, newTodo);
      })
      .catch(() => {
        sendResponse(response, 400, { error: "Invalid request body" });
      });
  } else if (method === 'GET' && path.match(/^\/todos\/\d+$/)) {
    const todoId = parseInt(path.split('/')[2]);
    const todo = TodoManager.getTodoByIdAndUserId(todoId, currentUser.id);
    
    if (!todo) {
      sendResponse(response, 404, { error: "Todo not found" });
      return;
    }
    
    sendResponse(response, 200, todo);
  } else if (method === 'PUT' && path.match(/^\/todos\/\d+$/)) {
    const todoId = parseInt(path.split('/')[2]);
    
    parseRequestBody(request)
      .then(body => {
        const { title, description, completed } = body;
        
        if (typeof title === 'string' && title.trim() === '') {
          sendResponse(response, 400, { error: "Title is required" });
          return;
        }
        
        const updatedTodo = TodoManager.updateTodo(todoId, currentUser.id, {
          title,
          description,
          completed
        });
        
        if (!updatedTodo) {
          sendResponse(response, 404, { error: "Todo not found" });
          return;
        }
        
        sendResponse(response, 200, updatedTodo);
      })
      .catch(() => {
        sendResponse(response, 400, { error: "Invalid request body" });
      });
  } else if (method === 'DELETE' && path.match(/^\/todos\/\d+$/)) {
    const todoId = parseInt(path.split('/')[2]);
    
    const success = TodoManager.deleteTodo(todoId, currentUser.id);
    
    if (!success) {
      sendResponse(response, 404, { error: "Todo not found" });
      return;
    }
    
    sendResponse(response, 204, null); // 204 No Content
  } else {
    sendResponse(response, 404, { error: "Not Found" });
  }
}

function startServer(port) {
  const server = http.createServer(handleRequest);
  
  server.listen({ host: '0.0.0.0', port: port }, () => {
    console.log(`Server running at http://0.0.0.0:${port}/`);
  });
  
  return server;
}

if (require.main === module) {
  // Parse command line arguments
  const args = process.argv.slice(2);
  const portArgIndex = args.indexOf('--port');
  const port = portArgIndex !== -1 ? parseInt(args[portArgIndex + 1]) : 3000;
  
  startServer(port);
}

module.exports = { startServer };