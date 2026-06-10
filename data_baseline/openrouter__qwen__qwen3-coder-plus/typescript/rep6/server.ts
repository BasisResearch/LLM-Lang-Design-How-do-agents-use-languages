import * as http from 'http';
import * as url from 'url';
import { v4 as uuidv4 } from 'uuid';
import * as crypto from 'crypto';
import * as yargs from 'yargs';

// In-memory data storage - not persisted across restarts
const users: Map<number, { id: number; username: string; hashedPassword: string }> = new Map();
const todos: Map<number, { 
  id: number; 
  userId: number; 
  title: string; 
  description: string; 
  completed: boolean; 
  created_at: string; 
  updated_at: string 
}> = new Map();
const sessions: Map<string, number> = new Map(); // Maps session_id to user_id
let nextUserId = 1;
let nextTodoId = 1;

interface UserRegistration {
  username: string;
  password: string;
}

interface UserLogin {
  username: string;
  password: string;
}

interface PasswordChange {
  old_password: string;
  new_password: string;
}

interface TodoCreation {
  title: string;
  description: string;
}

interface TodoUpdate {
  title?: string;
  description?: string;
  completed?: boolean;
}

// Helper functions
function getCurrentTimestamp(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function hashPassword(password: string): string {
  return crypto.createHash('sha256').update(password).digest('hex');
}

function validateUsername(username: string): boolean {
  const regex = /^[a-zA-Z0-9_]+$/;
  return typeof username === 'string' && username.length >= 3 && username.length <= 50 && regex.test(username);
}

function validateSession(sessionId: string | undefined): number | null {
  if (!sessionId || !sessions.has(sessionId)) {
    return null;
  }
  return sessions.get(sessionId)!;
}

function sendResponse(
  res: http.ServerResponse,
  statusCode: number,
  data?: any,
  headers?: { [key: string]: string }
): void {
  if (headers) {
    for (const [key, value] of Object.entries(headers)) {
      res.setHeader(key, value);
    }
  }
  
  res.setHeader('Content-Type', 'application/json');
  res.writeHead(statusCode);
  
  if (data !== undefined) {
    res.end(JSON.stringify(data));
  } else if (statusCode !== 204) {
    res.end('');
  }
}

function parseRequestBody(req: http.IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk.toString();
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (error) {
        reject(error);
      }
    });
  });
}

function handleRegister(
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  parseRequestBody(req)
    .then((body: UserRegistration) => {
      if (!body.username) {
        sendResponse(res, 400, { error: "Invalid username" });
        return;
      }

      if (!validateUsername(body.username)) {
        sendResponse(res, 400, { error: "Invalid username" });
        return;
      }

      if (!body.password) {
        sendResponse(res, 400, { error: "Password too short" });
        return;
      }

      if (body.password.length < 8) {
        sendResponse(res, 400, { error: "Password too short" });
        return;
      }

      // Check if username exists
      for (const [_, user] of users) {
        if (user.username === body.username) {
          sendResponse(res, 409, { error: "Username already exists" });
          return;
        }
      }

      // Create new user
      const newUser = {
        id: nextUserId,
        username: body.username,
        hashedPassword: hashPassword(body.password)
      };
      
      users.set(nextUserId, newUser);
      nextUserId++;
      
      sendResponse(res, 201, { id: newUser.id, username: newUser.username });
    })
    .catch(() => {
      sendResponse(res, 400, { error: "Invalid request body" });
    });
}

function handleLogin(
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  parseRequestBody(req)
    .then((body: UserLogin) => {
      if (!body.username || !body.password) {
        sendResponse(res, 401, { error: "Invalid credentials" });
        return;
      }

      let userFound = false;
      let matchedUser = null;

      for (const [_, user] of users) {
        if (user.username === body.username && user.hashedPassword === hashPassword(body.password)) {
          userFound = true;
          matchedUser = user;
          break;
        }
      }

      if (!userFound) {
        sendResponse(res, 401, { error: "Invalid credentials" });
        return;
      }

      // Generate session ID
      const sessionId = uuidv4();
      sessions.set(sessionId, matchedUser!.id);

      // Set session cookie and return user info
      const responseHeaders = {
        'Set-Cookie': `session_id=${sessionId}; Path=/; HttpOnly`
      };
      
      sendResponse(res, 200, { id: matchedUser!.id, username: matchedUser!.username }, responseHeaders);
    })
    .catch(() => {
      sendResponse(res, 400, { error: "Invalid request body" });
    });
}

function handleLogout(
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  const cookies = req.headers.cookie?.split(';').reduce((acc, cookieStr) => {
    const parts = cookieStr.trim().split('=');
    if (parts.length === 2) {
      acc[parts[0]] = parts[1];
    }
    return acc;
  }, {} as { [key: string]: string });

  const sessionId = cookies?.session_id;

  if (!sessionId || !sessions.has(sessionId)) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  // Remove the session
  sessions.delete(sessionId);
  
  sendResponse(res, 200, {});
}

function handleGetMe(
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  const cookies = req.headers.cookie?.split(';').reduce((acc, cookieStr) => {
    const parts = cookieStr.trim().split('=');
    if (parts.length === 2) {
      acc[parts[0]] = parts[1];
    }
    return acc;
  }, {} as { [key: string]: string });

  const sessionId = cookies?.session_id;

  const userId = validateSession(sessionId);
  if (userId === null) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  const user = users.get(userId);
  if (!user) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  sendResponse(res, 200, { id: user.id, username: user.username });
}

function handleChangePassword(
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  const cookies = req.headers.cookie?.split(';').reduce((acc, cookieStr) => {
    const parts = cookieStr.trim().split('=');
    if (parts.length === 2) {
      acc[parts[0]] = parts[1];
    }
    return acc;
  }, {} as { [key: string]: string });

  const sessionId = cookies?.session_id;

  const userId = validateSession(sessionId);
  if (userId === null) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  parseRequestBody(req)
    .then((body: PasswordChange) => {
      if (!body.old_password || !body.new_password) {
        sendResponse(res, 400, { error: "Both old and new passwords are required" });
        return;
      }

      if (body.new_password.length < 8) {
        sendResponse(res, 400, { error: "Password too short" });
        return;
      }

      const user = users.get(userId);
      if (!user || user.hashedPassword !== hashPassword(body.old_password)) {
        sendResponse(res, 401, { error: "Invalid credentials" });
        return;
      }

      // Update the password
      user.hashedPassword = hashPassword(body.new_password);
      users.set(userId, user);

      sendResponse(res, 200, {});
    })
    .catch(() => {
      sendResponse(res, 400, { error: "Invalid request body" });
    });
}

function handleGetTodos(
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  const cookies = req.headers.cookie?.split(';').reduce((acc, cookieStr) => {
    const parts = cookieStr.trim().split('=');
    if (parts.length === 2) {
      acc[parts[0]] = parts[1];
    }
    return acc;
  }, {} as { [key: string]: string });

  const sessionId = cookies?.session_id;

  const userId = validateSession(sessionId);
  if (userId === null) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  // Filter todos for current user
  const userTodos: Array<{
    id: number;
    title: string;
    description: string;
    completed: boolean;
    created_at: string;
    updated_at: string;
  }> = [];

  for (const [_, todo] of todos) {
    if (todo.userId === userId) {
      userTodos.push({
        id: todo.id,
        title: todo.title,
        description: todo.description,
        completed: todo.completed,
        created_at: todo.created_at,
        updated_at: todo.updated_at
      });
    }
  }

  // Sort by id ascending
  userTodos.sort((a, b) => a.id - b.id);

  sendResponse(res, 200, userTodos);
}

function handleCreateTodo(
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  const cookies = req.headers.cookie?.split(';').reduce((acc, cookieStr) => {
    const parts = cookieStr.trim().split('=');
    if (parts.length === 2) {
      acc[parts[0]] = parts[1];
    }
    return acc;
  }, {} as { [key: string]: string });

  const sessionId = cookies?.session_id;

  const userId = validateSession(sessionId);
  if (userId === null) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  parseRequestBody(req)
    .then((body: TodoCreation) => {
      if (!body.title || body.title.trim() === '') {
        sendResponse(res, 400, { error: "Title is required" });
        return;
      }

      const createdAt = getCurrentTimestamp();
      const newTodo = {
        id: nextTodoId,
        userId: userId,
        title: body.title,
        description: body.description || "",
        completed: false,
        created_at: createdAt,
        updated_at: createdAt
      };

      todos.set(nextTodoId, newTodo);
      nextTodoId++;

      sendResponse(res, 201, newTodo);
    })
    .catch(() => {
      sendResponse(res, 400, { error: "Invalid request body" });
    });
}

function handleGetTodoById(
  pathname: string | undefined,
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  const cookies = req.headers.cookie?.split(';').reduce((acc, cookieStr) => {
    const parts = cookieStr.trim().split('=');
    if (parts.length === 2) {
      acc[parts[0]] = parts[1];
    }
    return acc;
  }, {} as { [key: string]: string });

  const sessionId = cookies?.session_id;

  const userId = validateSession(sessionId);
  if (userId === null) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  if (!pathname) {
    sendResponse(res, 400, { error: "Bad request" });
    return;
  }

  const segments = pathname.split('/');
  if (segments.length < 3) {
    sendResponse(res, 404, { error: "Todo not found" });
    return;
  }
  const id = parseInt(segments[2]); // Extract todo ID from URL path like /todos/123
  const todo = todos.get(id);

  if (!todo || todo.userId !== userId) {
    sendResponse(res, 404, { error: "Todo not found" });
    return;
  }

  sendResponse(res, 200, {
    id: todo.id,
    title: todo.title,
    description: todo.description,
    completed: todo.completed,
    created_at: todo.created_at,
    updated_at: todo.updated_at
  });
}

function handleUpdateTodoById(
  pathname: string | undefined,
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  const cookies = req.headers.cookie?.split(';').reduce((acc, cookieStr) => {
    const parts = cookieStr.trim().split('=');
    if (parts.length === 2) {
      acc[parts[0]] = parts[1];
    }
    return acc;
  }, {} as { [key: string]: string });

  const sessionId = cookies?.session_id;

  const userId = validateSession(sessionId);
  if (userId === null) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  if (!pathname) {
    sendResponse(res, 400, { error: "Bad request" });
    return;
  }

  const segments = pathname.split('/');
  if (segments.length < 3) {
    sendResponse(res, 404, { error: "Todo not found" });
    return;
  }
  const id = parseInt(segments[2]); // Extract todo ID from URL path like /todos/123
  const todo = todos.get(id);

  if (!todo || todo.userId !== userId) {
    sendResponse(res, 404, { error: "Todo not found" });
    return;
  }

  parseRequestBody(req)
    .then((body: Partial<TodoUpdate>) => {
      // Validate title if present in request
      if (body.title !== undefined && (body.title === "" || body.title.trim() === "")) {
        sendResponse(res, 400, { error: "Title is required" });
        return;
      }

      // Update only provided fields, keeping existing values for others
      const updatedTodo = {
        ...todo,
        title: body.title !== undefined ? body.title : todo.title,
        description: body.description !== undefined ? body.description : todo.description,
        completed: body.completed !== undefined ? body.completed : todo.completed,
        updated_at: getCurrentTimestamp()  // Always update the timestamp
      };

      todos.set(id, updatedTodo);

      sendResponse(res, 200, updatedTodo);
    })
    .catch(() => {
      sendResponse(res, 400, { error: "Invalid request body" });
    });
}

function handleDeleteTodoById(
  pathname: string | undefined,
  req: http.IncomingMessage,
  res: http.ServerResponse
): void {
  const cookies = req.headers.cookie?.split(';').reduce((acc, cookieStr) => {
    const parts = cookieStr.trim().split('=');
    if (parts.length === 2) {
      acc[parts[0]] = parts[1];
    }
    return acc;
  }, {} as { [key: string]: string });

  const sessionId = cookies?.session_id;

  const userId = validateSession(sessionId);
  if (userId === null) {
    sendResponse(res, 401, { error: "Authentication required" });
    return;
  }

  if (!pathname) {
    sendResponse(res, 400, { error: "Bad request" });
    return;
  }

  const segments = pathname.split('/');
  if (segments.length < 3) {
    sendResponse(res, 404, { error: "Todo not found" });
    return;
  }
  const id = parseInt(segments[2]); // Extract todo ID from URL path like /todos/123
  const todo = todos.get(id);

  if (!todo || todo.userId !== userId) {
    sendResponse(res, 404, { error: "Todo not found" });
    return;
  }

  todos.delete(id);
  sendResponse(res, 204);
}

// Main request handler
function requestHandler(req: http.IncomingMessage, res: http.ServerResponse): void {
  const parsedUrl = url.parse(req.url!, true);
  const pathname = parsedUrl.pathname;
  const method = req.method;

  // Handle CORS preflight
  if (method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Cookie');
    res.writeHead(204);
    res.end();
    return;
  }

  try {
    if (method === 'POST' && pathname === '/register') {
      handleRegister(req, res);
    } else if (method === 'POST' && pathname === '/login') {
      handleLogin(req, res);
    } else if (method === 'POST' && pathname === '/logout') {
      handleLogout(req, res);
    } else if (method === 'GET' && pathname === '/me') {
      handleGetMe(req, res);
    } else if (method === 'PUT' && pathname === '/password') {
      handleChangePassword(req, res);
    } else if (method === 'GET' && pathname === '/todos') {
      handleGetTodos(req, res);
    } else if (method === 'POST' && pathname === '/todos') {
      handleCreateTodo(req, res);
    } else if (method === 'GET' && pathname?.startsWith('/todos/')) {
      handleGetTodoById(pathname, req, res);
    } else if (method === 'PUT' && pathname?.startsWith('/todos/')) {
      handleUpdateTodoById(pathname, req, res);
    } else if (method === 'DELETE' && pathname?.startsWith('/todos/')) {
      handleDeleteTodoById(pathname, req, res);
    } else {
      sendResponse(res, 404, { error: "Endpoint not found" });
    }
  } catch (error) {
    console.error("Error handling request:", error);
    sendResponse(res, 500, { error: "Internal server error" });
  }
}

// Parse command line arguments
const argv = yargs.argv;
const port = argv.port || 3000;

// Start server
const server = http.createServer(requestHandler);

server.listen(port, '0.0.0.0', () => {
  console.log(`Server running on http://0.0.0.0:${port}`);
});