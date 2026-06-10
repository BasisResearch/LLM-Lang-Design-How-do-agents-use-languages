import http from 'http';
import url from 'url';
import crypto from 'crypto';
import { v4 as uuidv4 } from 'uuid';

// In-memory storage
interface User {
  id: number;
  username: string;
  passwordHash: string; // In real app we'd use proper hashing, but for simulation we store simple
}

interface Todo {
  id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
  userId: number; // Reference to the user who owns this todo
}

// Global storage instances
let users: User[] = [];
let todos: Todo[] = [];
let sessions: Map<string, number> = new Map(); // Maps session_id to user_id
let nextUserId: number = 1;
let nextTodoId: number = 1;

// Generate a hash for passwords (for demo we'll use a basic hash function)
function hashPassword(password: string): string {
  return crypto.createHash('sha256').update(password).digest('hex');
}

// Validate username: 3-50 characters, alphanumeric and underscore only
function isValidUsername(username: string): boolean {
  const regex = /^[a-zA-Z0-9_]+$/;
  return username.length >= 3 && username.length <= 50 && regex.test(username);
}

// Get current timestamp in ISO 8601 format
function getCurrentTimestamp(): string {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

// Parse body from request
async function parseBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk.toString();
    });
    req.on('end', () => {
      resolve(body);
    });
  });
}

// Extract session ID from cookies
function getSessionIdFromCookies(req: http.IncomingMessage): string | null {
  const cookieHeader = req.headers.cookie;
  if (!cookieHeader) return null;

  const cookies = cookieHeader.split('; ');
  for (const cookie of cookies) {
    const [name, ...values] = cookie.split('=');
    if (name === 'session_id') {
      return values.join('=');
    }
  }
  return null;
}

// Check if session is valid and get user ID
function getUserIdBySession(sessionId: string): number | null {
  return sessions.get(sessionId) || null;
}

// Find user by username
function findUserByUsername(username: string): User | null {
  return users.find(user => user.username === username) || null;
}

// Authenticate user by username and password
function authenticateUser(username: string, providedPassword: string): User | null {
  const user = findUserByUsername(username);
  if (user && user.passwordHash === hashPassword(providedPassword)) {
    return user;
  }
  return null;
}

// Create a new user
function createUser(username: string, password: string): User {
  const newUser: User = {
    id: nextUserId++,
    username,
    passwordHash: hashPassword(password)
  };
  users.push(newUser);
  return newUser;
}

// Create a new todo for specified user
function createTodo(userId: number, title: string, description: string): Todo {
  const newTodo: Todo = {
    id: nextTodoId++,
    title,
    description: description || '',
    completed: false,
    created_at: getCurrentTimestamp(),
    updated_at: getCurrentTimestamp(),
    userId
  };
  todos.push(newTodo);
  return newTodo;
}

// Find todo by ID and user ID
function findTodoByIdAndUser(todoId: number, userId: number): Todo | null {
  return todos.find(todo => todo.id === todoId && todo.userId === userId) || null;
}

// Main server handler
const server = http.createServer(async (req, res) => {
  const parsedUrl = url.parse(req.url!, true);
  const pathname = parsedUrl.pathname;
  const method = req.method;

  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Content-Type', 'application/json');

  // Handle preflight requests
  if (method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  try {
    // Public endpoints (no auth required)
    if (pathname === '/register' && method === 'POST') {
      handleRegister(req, res);
      return;
    } else if (pathname === '/login' && method === 'POST') {
      handleLogin(req, res);
      return;
    }

    // Authenticated endpoints (require session)
    // First check auth for protected routes
    const protectedPaths = ['/me', '/password', '/todos', '/logout'];
    const isProtectedPath = protectedPaths.some(path => 
      pathname?.startsWith(path) || 
      (pathname?.includes('/todos/') && method !== 'POST' && pathname.split('/')[1] === 'todos')
    );

    if (isProtectedPath) {
      const sessionId = getSessionIdFromCookies(req);
      if (!sessionId || !getUserIdBySession(sessionId)) {
        res.writeHead(401);
        res.end(JSON.stringify({ error: 'Authentication required' }));
        return;
      }
    }

    // Route to appropriate handler based on pathname and method
    if (pathname === '/register' && method === 'POST') {
      await handleRegister(req, res);
    } else if (pathname === '/login' && method === 'POST') {
      await handleLogin(req, res);
    } else if (pathname === '/logout' && method === 'POST') {
      await handleLogout(req, res);
    } else if (pathname === '/me' && method === 'GET') {
      await handleMe(req, res);
    } else if (pathname === '/password' && method === 'PUT') {
      await handlePassword(req, res);
    } else if (pathname === '/todos' && method === 'GET') {
      await handleGetTodos(req, res);
    } else if (pathname === '/todos' && method === 'POST') {
      await handleCreateTodo(req, res);
    } else if (pathname?.match(/^\/todos\/\d+$/) && method === 'GET') {
      await handleGetTodoById(req, res, parseInt(pathname.split('/')[2]));
    } else if (pathname?.match(/^\/todos\/\d+$/) && method === 'PUT') {
      await handleUpdateTodo(req, res, parseInt(pathname.split('/')[2]));
    } else if (pathname?.match(/^\/todos\/\d+$/) && method === 'DELETE') {
      await handleDeleteTodo(req, res, parseInt(pathname.split('/')[2]));
    } else {
      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Not Found' }));
    }
  } catch (err) {
    console.error(err);
    res.writeHead(500);
    res.end(JSON.stringify({ error: 'Internal Server Error' }));
  }
});

// Register endpoint
async function handleRegister(req: http.IncomingMessage, res: http.ServerResponse) {
  try {
    const body = await parseBody(req);
    const { username, password } = JSON.parse(body);

    // Validate username
    if (!username || typeof username !== 'string' || !isValidUsername(username)) {
      res.writeHead(400);
      res.end(JSON.stringify({ error: 'Invalid username' }));
      return;
    }

    // Validate password
    if (!password || typeof password !== 'string' || password.length < 8) {
      res.writeHead(400);
      res.end(JSON.stringify({ error: 'Password too short' }));
      return;
    }

    // Check if username already exists
    if (findUserByUsername(username)) {
      res.writeHead(409);
      res.end(JSON.stringify({ error: 'Username already exists' }));
      return;
    }

    const newUser = createUser(username, password);
    
    res.writeHead(201);
    res.end(JSON.stringify({ id: newUser.id, username: newUser.username }));
  } catch (err) {
    res.writeHead(400);
    res.end(JSON.stringify({ error: 'Invalid request body' }));
  }
}

// Login endpoint
async function handleLogin(req: http.IncomingMessage, res: http.ServerResponse) {
  try {
    const body = await parseBody(req);
    const { username, password } = JSON.parse(body);

    // Authenticate the user
    const user = authenticateUser(username, password);
    if (!user) {
      res.writeHead(401);
      res.end(JSON.stringify({ error: 'Invalid credentials' }));
      return;
    }

    // Create a new session
    const sessionId = uuidv4();
    sessions.set(sessionId, user.id);

    // Set cookie and respond
    res.setHeader('Set-Cookie', [`session_id=${sessionId}; Path=/; HttpOnly`]);
    res.writeHead(200);
    res.end(JSON.stringify({ id: user.id, username: user.username }));
  } catch (err) {
    res.writeHead(400);
    res.end(JSON.stringify({ error: 'Invalid request body' }));
  }
}

// Logout endpoint
async function handleLogout(req: http.IncomingMessage, res: http.ServerResponse) {
  const sessionId = getSessionIdFromCookies(req);

  if (sessionId && sessions.has(sessionId)) {
    sessions.delete(sessionId);
  }

  res.writeHead(200);
  res.end(JSON.stringify({}));
}

// Get current user endpoint
async function handleMe(req: http.IncomingMessage, res: http.ServerResponse) {
  const sessionId = getSessionIdFromCookies(req);
  const userId = getUserIdBySession(sessionId!); // We know it exists because middleware checked

  if (!userId) {
    res.writeHead(401);
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }

  const user = users.find(u => u.id === userId);
  if (!user) {
    res.writeHead(401);
    res.end(JSON.stringify({ error: 'Authentication required' }));
    return;
  }

  res.writeHead(200);
  res.end(JSON.stringify({ id: user.id, username: user.username }));
}

// Change password endpoint
async function handlePassword(req: http.IncomingMessage, res: http.ServerResponse) {
  const sessionId = getSessionIdFromCookies(req);
  const userId = getUserIdBySession(sessionId!);

  try {
    const body = await parseBody(req);
    const { old_password, new_password } = JSON.parse(body);

    // Find the user
    const user = users.find(u => u.id === userId);
    if (!user) {
      res.writeHead(401);
      res.end(JSON.stringify({ error: 'Invalid credentials' }));
      return;
    }

    // Verify old password
    if (user.passwordHash !== hashPassword(old_password)) {
      res.writeHead(401);
      res.end(JSON.stringify({ error: 'Invalid credentials' }));
      return;
    }

    // Validate new password
    if (!new_password || typeof new_password !== 'string' || new_password.length < 8) {
      res.writeHead(400);
      res.end(JSON.stringify({ error: 'Password too short' }));
      return;
    }

    // Update password
    user.passwordHash = hashPassword(new_password);

    res.writeHead(200);
    res.end(JSON.stringify({}));
  } catch (err) {
    res.writeHead(400);
    res.end(JSON.stringify({ error: 'Invalid request body' }));
  }
}

// Get all todos for user endpoint
async function handleGetTodos(req: http.IncomingMessage, res: http.ServerResponse) {
  const sessionId = getSessionIdFromCookies(req);
  const userId = getUserIdBySession(sessionId!);

  // Filter todos to only those belonging to the user
  const userTodos = todos.filter(todo => todo.userId === userId).sort((a, b) => a.id - b.id);

  res.writeHead(200);
  res.end(JSON.stringify(userTodos));
}

// Create new todo endpoint
async function handleCreateTodo(req: http.IncomingMessage, res: http.ServerResponse) {
  const sessionId = getSessionIdFromCookies(req);
  const userId = getUserIdBySession(sessionId!);

  try {
    const body = await parseBody(req);
    const { title, description } = JSON.parse(body);

    // Validate title
    if (!title || typeof title !== 'string' || title.trim() === '') {
      res.writeHead(400);
      res.end(JSON.stringify({ error: 'Title is required' }));
      return;
    }

    // Create the todo
    const newTodo = createTodo(userId!, title, description || '');

    res.writeHead(201);
    res.end(JSON.stringify(newTodo));
  } catch (err) {
    res.writeHead(400);
    res.end(JSON.stringify({ error: 'Invalid request body' }));
  }
}

// Get a specific todo by ID
async function handleGetTodoById(req: http.IncomingMessage, res: http.ServerResponse, todoId: number) {
  const sessionId = getSessionIdFromCookies(req);
  const userId = getUserIdBySession(sessionId!);

  const todo = findTodoByIdAndUser(todoId, userId!);
  if (!todo) {
    res.writeHead(404);
    res.end(JSON.stringify({ error: 'Todo not found' }));
    return;
  }

  res.writeHead(200);
  res.end(JSON.stringify(todo));
}

// Update a specific todo by ID (partial update)
async function handleUpdateTodo(req: http.IncomingMessage, res: http.ServerResponse, todoId: number) {
  const sessionId = getSessionIdFromCookies(req);
  const userId = getUserIdBySession(sessionId!);

  try {
    const body = await parseBody(req);
    const updates = JSON.parse(body);

    // Get the current todo
    const existingTodo = findTodoByIdAndUser(todoId, userId!);
    if (!existingTodo) {
      res.writeHead(404);
      res.end(JSON.stringify({ error: 'Todo not found' }));
      return;
    }

    // Validate title if provided
    if ('title' in updates && (typeof updates.title !== 'string' || updates.title.trim() === '')) {
      res.writeHead(400);
      res.end(JSON.stringify({ error: 'Title is required' }));
      return;
    }

    // Perform the update with provided fields only
    if ('title' in updates) {
      existingTodo.title = updates.title;
    }
    if ('description' in updates) {
      existingTodo.description = updates.description;
    }
    if ('completed' in updates) {
      existingTodo.completed = Boolean(updates.completed);
    }
    existingTodo.updated_at = getCurrentTimestamp();

    res.writeHead(200);
    res.end(JSON.stringify(existingTodo));
  } catch (err) {
    res.writeHead(400);
    res.end(JSON.stringify({ error: 'Invalid request body' }));
  }
}

// Delete a specific todo by ID
async function handleDeleteTodo(req: http.IncomingMessage, res: http.ServerResponse, todoId: number) {
  const sessionId = getSessionIdFromCookies(req);
  const userId = getUserIdBySession(sessionId!);

  // Find the index of the todo to remove
  const todoIndex = todos.findIndex(todo => todo.id === todoId && todo.userId === userId!);
  if (todoIndex === -1) {
    res.writeHead(404);
    res.end(JSON.stringify({ error: 'Todo not found' }));
    return;
  }

  // Remove the todo
  todos.splice(todoIndex, 1);

  res.writeHead(204);
  res.end();
}

// Detect if script is being run directly
const isMainModule = typeof module !== 'undefined' && require.main === module;

// Start the server if this file is run directly
if (isMainModule) {
  const args = process.argv.slice(2);
  const portArgIndex = args.indexOf('--port');
  const port = portArgIndex !== -1 ? parseInt(args[portArgIndex + 1]) : 3000;

  server.listen(port, '0.0.0.0', () => {
    console.log(`Server running on http://0.0.0.0:${port}`);
  });
}

export default server;