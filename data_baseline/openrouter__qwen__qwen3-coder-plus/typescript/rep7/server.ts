import express, { Request, Response } from 'express';
import cookieParser from 'cookie-parser';
import bcrypt from 'bcryptjs';
import { v4 as uuidv4 } from 'uuid';

// In-memory storage
const users: Map<number, { id: number; username: string; passwordHash: string }> = new Map();
const todos: Map<number, { 
  id: number;
  userId: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
}> = new Map();
const sessions: Map<string, number> = new Map(); // session_id -> user_id

// Generate auto-incrementing IDs
let nextUserId = 1;
let nextTodoId = 1;

const app = express();

// Middleware
app.use(express.json());
app.use(cookieParser());

// Helper functions
const getCurrentTimestamp = (): string => {
  return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
};

const generateSessionId = (): string => {
  return uuidv4();
};

// Validate username format
const isValidUsername = (username: string): boolean => {
  return /^[a-zA-Z0-9_]{3,50}$/.test(username);
};

// Auth middleware
const authenticate = (req: Request, res: Response, next: () => void): void => {
  const sessionId = req.cookies.session_id;
  if (!sessionId || !sessions.has(sessionId)) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  next();
};

// Helper to find user by session
const getUserBySession = (req: Request): number | null => {
  const sessionId = req.cookies.session_id;
  if (!sessionId || !sessions.has(sessionId)) {
    return null;
  }
  return sessions.get(sessionId) || null;
};

// POST /register
app.post('/register', async (req, res) => {
  try {
    const { username, password } = req.body;

    // Validate username
    if (!username || !isValidUsername(username)) {
      res.status(400).json({ error: "Invalid username" });
      return;
    }

    // Validate password
    if (!password || password.length < 8) {
      res.status(400).json({ error: "Password too short" });
      return;
    }

    // Check if username already exists
    for (const user of users.values()) {
      if (user.username === username) {
        res.status(409).json({ error: "Username already exists" });
        return;
      }
    }

    // Create user
    const hashedPassword = await bcrypt.hash(password, 10);
    const newUser = {
      id: nextUserId,
      username,
      passwordHash: hashedPassword
    };
    
    users.set(nextUserId, newUser);
    nextUserId++;

    res.status(201).json({
      id: newUser.id,
      username: newUser.username
    });
  } catch (err) {
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /login
app.post('/login', async (req, res) => {
  try {
    const { username, password } = req.body;

    // Find user
    let foundUser = null;
    for (const user of users.values()) {
      if (user.username === username) {
        foundUser = user;
        break;
      }
    }

    if (!foundUser || !(await bcrypt.compare(password, foundUser.passwordHash))) {
      res.status(401).json({ error: "Invalid credentials" });
      return;
    }

    // Generate session
    const sessionId = generateSessionId();
    sessions.set(sessionId, foundUser.id);

    res.cookie('session_id', sessionId, { 
      httpOnly: true, 
      path: '/' 
    });

    res.status(200).json({
      id: foundUser.id,
      username: foundUser.username
    });
  } catch (err) {
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /logout
app.post('/logout', authenticate, (req, res) => {
  const sessionId = req.cookies.session_id;
  
  if (sessionId && sessions.has(sessionId)) {
    sessions.delete(sessionId);
  }

  res.status(200).json({});
});

// GET /me
app.get('/me', authenticate, (req, res) => {
  const userId = getUserBySession(req);
  
  if (!userId || !users.has(userId)) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }

  const user = users.get(userId)!;
  res.status(200).json({
    id: user.id,
    username: user.username
  });
});

// PUT /password
app.put('/password', authenticate, async (req, res) => {
  try {
    const userId = getUserBySession(req);
    const { old_password, new_password } = req.body;

    if (!userId) {
      res.status(401).json({ error: "Authentication required" });
      return;
    }

    const user = users.get(userId);
    if (!user) {
      res.status(401).json({ error: "Authentication required" });
      return;
    }

    if (!old_password || !(await bcrypt.compare(old_password, user.passwordHash))) {
      res.status(401).json({ error: "Invalid credentials" });
      return;
    }

    if (!new_password || new_password.length < 8) {
      res.status(400).json({ error: "Password too short" });
      return;
    }

    // Update password
    const hashedNewPassword = await bcrypt.hash(new_password, 10);
    user.passwordHash = hashedNewPassword;

    res.status(200).json({});
  } catch (err) {
    res.status(500).json({ error: "Internal server error" });
  }
});

// GET /todos
app.get('/todos', authenticate, (req, res) => {
  const userId = getUserBySession(req);

  if (!userId) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }

  const userTodos = [];
  for (const todo of todos.values()) {
    if (todo.userId === userId) {
      userTodos.push(todo);
    }
  }

  // Sort by id ascending
  userTodos.sort((a, b) => a.id - b.id);

  res.status(200).json(userTodos);
});

// POST /todos
app.post('/todos', authenticate, (req, res) => {
  try {
    const userId = getUserBySession(req);
    const { title, description } = req.body;

    if (!userId) {
      res.status(401).json({ error: "Authentication required" });
      return;
    }

    if (!title || title.trim() === '') {
      res.status(400).json({ error: "Title is required" });
      return;
    }

    const createdAt = getCurrentTimestamp();
    const updatedAt = getCurrentTimestamp();

    const newTodo = {
      id: nextTodoId,
      userId,
      title: title.trim(),
      description: description ? description.trim() : '',
      completed: false,
      created_at: createdAt,
      updated_at: updatedAt
    };

    todos.set(nextTodoId, newTodo);
    nextTodoId++;

    res.status(201).json(newTodo);
  } catch (err) {
    res.status(500).json({ error: "Internal server error" });
  }
});

// GET /todos/:id
app.get('/todos/:id', authenticate, (req, res) => {
  const userId = getUserBySession(req);
  const todoId = parseInt(req.params.id);

  if (!userId) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }

  const todo = todos.get(todoId);

  if (!todo || todo.userId !== userId) {
    res.status(404).json({ error: "Todo not found" });
    return;
  }

  res.status(200).json(todo);
});

// PUT /todos/:id
app.put('/todos/:id', authenticate, (req, res) => {
  try {
    const userId = getUserBySession(req);
    const todoId = parseInt(req.params.id);
    const { title, description, completed } = req.body;

    if (!userId) {
      res.status(401).json({ error: "Authentication required" });
      return;
    }

    const todo = todos.get(todoId);

    if (!todo || todo.userId !== userId) {
      res.status(404).json({ error: "Todo not found" });
      return;
    }

    // Validate title if provided
    if (title !== undefined && title.trim() === '') {
      res.status(400).json({ error: "Title is required" });
      return;
    }

    // Update todo properties if provided
    if (title !== undefined) {
      todo.title = title.trim();
    }
    if (description !== undefined) {
      todo.description = description.trim();
    }
    if (completed !== undefined) {
      todo.completed = !!completed;
    }
    
    todo.updated_at = getCurrentTimestamp();

    res.status(200).json(todo);
  } catch (err) {
    res.status(500).json({ error: "Internal server error" });
  }
});

// DELETE /todos/:id
app.delete('/todos/:id', authenticate, (req, res) => {
  const userId = getUserBySession(req);
  const todoId = parseInt(req.params.id);

  if (!userId) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }

  const todo = todos.get(todoId);

  if (!todo || todo.userId !== userId) {
    res.status(404).json({ error: "Todo not found" });
    return;
  }

  todos.delete(todoId);
  res.status(204).send(); // No content
});

// Handle command-line --port argument
const argPort = process.argv.indexOf('--port');
let port = 3000;

if (argPort !== -1 && process.argv[argPort + 1]) {
  const portArg = parseInt(process.argv[argPort + 1]);
  if (!isNaN(portArg) && portArg > 0 && portArg <= 65535) {
    port = portArg;
  }
}

// Start server
app.listen(port, '0.0.0.0', () => {
  console.log(`Server running on 0.0.0.0:${port}`);
});