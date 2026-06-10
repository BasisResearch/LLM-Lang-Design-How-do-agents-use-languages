import express, { Request, Response } from 'express';
import { v4 as uuidv4 } from 'uuid';
import bcrypt from 'bcrypt';

// Type definitions
interface User {
  id: number;
  username: string;
  passwordHash: string;
}

interface Todo {
  id: number;
  userId: number; // Foreign key to user
  title: string;
  description: string;
  completed: boolean;
  created_at: string; // ISO 8601 UTC format
  updated_at: string; // ISO 8601 UTC format
}

// In-memory storage
const users: Record<number, User> = {};
let nextUserId = 1;

const todos: Record<number, Todo> = {};
let nextTodoId = 1;

// Session storage (in-memory)
const sessions: Record<string, number> = {}; // Maps session_id to user_id

// Helper function to generate current timestamp in ISO 8601 format
const getCurrentTimestamp = (): string => {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
};

// Helper function to validate username format
const validateUsername = (username: string): boolean => {
  const regex = /^[a-zA-Z0-9_]+$/;
  return username.length >= 3 && username.length <= 50 && regex.test(username);
};

// Middleware to require authentication
const requireAuth = (req: Request, res: Response, next: () => void) => {
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  
  if (!sessionId || !sessions[sessionId]) {
    return res.status(401).json({ error: "Authentication required" });
  }
  
  next();
};

// Initialize Express app
const app = express();

// Middleware to parse JSON
app.use(express.json());

// Parse cookies (manually since we're not using cookie-parser)
app.use((req, res, next) => {
  if (req.headers.cookie) {
    const cookies: Record<string, string> = {};
    req.headers.cookie.split(';').forEach(cookie => {
      const [name, value] = cookie.trim().split('=');
      cookies[name] = value;
    });
    req.cookies = cookies;
  } else {
    req.cookies = {};
  }
  next();
});

// POST /register
app.post('/register', async (req, res) => {
  const { username, password } = req.body;

  // Validate username
  if (!username || !validateUsername(username)) {
    return res.status(400).json({ error: "Invalid username" });
  }

  // Validate password length
  if (!password || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  // Check if username already exists
  for (const user of Object.values(users)) {
    if (user.username === username) {
      return res.status(409).json({ error: "Username already exists" });
    }
  }

  // Hash the password
  const passwordHash = await bcrypt.hash(password, 10);

  // Create new user
  const newUser: User = {
    id: nextUserId,
    username,
    passwordHash
  };
  
  users[nextUserId] = newUser;
  nextUserId++;

  res.status(201).json({
    id: newUser.id,
    username: newUser.username
  });
});

// POST /login
app.post('/login', async (req, res) => {
  const { username, password } = req.body;

  // Find user by username
  let targetUser: User | null = null;
  for (const user of Object.values(users)) {
    if (user.username === username) {
      targetUser = user;
      break;
    }
  }

  // Verify user exists and password matches
  if (!targetUser || !(await bcrypt.compare(password, targetUser.passwordHash))) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  // Generate session token
  const sessionId = uuidv4();
  sessions[sessionId] = targetUser.id;

  res.cookie('session_id', sessionId, {
    httpOnly: true,
    path: '/',
  });

  res.status(200).json({
    id: targetUser.id,
    username: targetUser.username
  });
});

// POST /logout
app.post('/logout', requireAuth, (req, res) => {
  const sessionId = req.cookies.session_id;
  
  if (sessionId && sessions[sessionId]) {
    delete sessions[sessionId];  // Remove the session from server
  }

  res.status(200).json({});
});

// GET /me
app.get('/me', requireAuth, (req, res) => {
  const sessionId = req.cookies.session_id;
  const userId = sessions[sessionId];

  const user = users[userId];

  if (!user) {
    return res.status(401).json({ error: "Authentication required" });  // Shouldn't happen due to middleware
  }

  res.status(200).json({
    id: user.id,
    username: user.username
  });
});

// PUT /password
app.put('/password', requireAuth, async (req, res) => {
  const sessionId = req.cookies.session_id;
  const userId = sessions[sessionId];
  const { old_password, new_password } = req.body;

  const user = users[userId];

  // Verify old password
  if (!await bcrypt.compare(old_password, user.passwordHash)) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  // Validate new password length
  if (!new_password || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  // Hash and update the new password
  const newPasswordHash = await bcrypt.hash(new_password, 10);
  user.passwordHash = newPasswordHash;

  res.status(200).json({});
});

// GET /todos
app.get('/todos', requireAuth, (req, res) => {
  const sessionId = req.cookies.session_id;
  const userId = sessions[sessionId];

  // Filter todos for this user only
  const userTodos = Object.values(todos).filter(todo => todo.userId === userId);
  
  // Sort by id ascending (as required by spec)
  userTodos.sort((a, b) => a.id - b.id);

  res.status(200).json(userTodos);
});

// POST /todos
app.post('/todos', requireAuth, (req, res) => {
  const sessionId = req.cookies.session_id;
  const userId = sessions[sessionId];
  const { title, description } = req.body;

  // Validate title is non-empty 
  if (!title || title.trim() === '') {
    return res.status(400).json({ error: "Title is required" });
  }

  const now = getCurrentTimestamp();

  // Create new todo
  const newTodo: Todo = {
    id: nextTodoId,
    userId: userId,        // Associate with the current user
    title: title,
    description: description || "",
    completed: false,      // Default to false
    created_at: now,
    updated_at: now
  };

  todos[nextTodoId] = newTodo;
  nextTodoId++;

  res.status(201).json(newTodo);
});

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req, res) => {
  const sessionId = req.cookies.session_id;
  const userId = sessions[sessionId];
  const todoId = parseInt(req.params.id, 10);

  if (isNaN(todoId)) {
    return res.status(400).json({ error: "Invalid todo ID" });
  }

  const todo = todos[todoId];

  // Check if todo exists AND belongs to the authenticated user
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  res.status(200).json(todo);
});

// PUT /todos/:id (partial update)
app.put('/todos/:id', requireAuth, (req, res) => {
  const sessionId = req.cookies.session_id;
  const userId = sessions[sessionId];
  const todoId = parseInt(req.params.id, 10);
  
  if (isNaN(todoId)) {
    return res.status(400).json({ error: "Invalid todo ID" });
  }

  const todo = todos[todoId];

  // Check if todo exists AND belongs to the authenticated user
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  // Update applicable fields
  if (req.body.title !== undefined) {
    if (typeof req.body.title !== 'string' || req.body.title.trim() === '') {
      return res.status(400).json({ error: "Title is required" });
    }
    todo.title = req.body.title;
  }

  if (req.body.description !== undefined) {
    todo.description = req.body.description;
  }

  if (req.body.completed !== undefined) {
    // Ensure completed is a boolean
    todo.completed = !!req.body.completed;
  }

  // Update the updated_at timestamp
  todo.updated_at = getCurrentTimestamp();

  res.status(200).json(todo);
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req, res) => {
  const sessionId = req.cookies.session_id;
  const userId = sessions[sessionId];
  const todoId = parseInt(req.params.id, 10);

  if (isNaN(todoId)) {
    return res.status(400).json({ error: "Invalid todo ID" });
  }

  const todo = todos[todoId];

  // Check if todo exists AND belongs to the authenticated user
  if (!todo || todo.userId !== userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  // Delete the todo
  delete todos[todoId];
  
  res.status(204).send();
});

export default app;

// Only run server when not being imported
if (require.main === module) {
  const args = process.argv.slice(2);
  let port = 3000; // default port
  
  // Parse -port argument
  const portIndex = args.indexOf('--port');
  if (portIndex !== -1 && args[portIndex + 1]) {
    port = parseInt(args[portIndex + 1], 10);
  }

  // Start the server
  app.listen(port, '0.0.0.0', () => {
    console.log(`Server is running on 0.0.0.0:${port}`);
  }).on('error', (err) => {
    console.error('Failed to start server:', err);
  });
}