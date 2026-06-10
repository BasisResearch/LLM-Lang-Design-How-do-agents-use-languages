import express, { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';
import cookieParser from 'cookie-parser';

// Type definitions
interface User {
  id: number;
  username: string;
  password: string;  // In a real app, this would be hashed
}

interface Todo {
  id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
  userId: number;
}

// Store data in memory
let users: User[] = [];
let todos: Todo[] = [];
let sessions: Map<string, number> = new Map();  // session_id -> user_id
let nextUserId: number = 1;
let nextTodoId: number = 1;

const app = express();

// Middleware
app.use(express.json());
app.use(cookieParser());

// Get ISO timestamp with second precision
function getTimestamp(): string {
  const now = new Date();
  return now.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// Generate session ID
function generateSessionId(): string {
  return crypto.randomBytes(32).toString('hex');
}

// Authentication middleware
const authenticate = (req: Request, res: Response, next: NextFunction): void => {
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  
  if (!sessionId || !sessions.has(sessionId)) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  next();
};

// Validation helpers
function validateUsername(username: string): boolean {
  return /^([a-zA-Z0-9_]){3,50}$/.test(username);
}

function validatePassword(password: string): boolean {
  return password.length >= 8;
}

// Routes
app.post('/register', (req: Request, res: Response): void => {
  const { username, password } = req.body;
  
  // Validate inputs
  if (!username) {
    res.status(400).json({ error: "Invalid username" });
    return;
  }
  
  if (!validateUsername(username)) {
    res.status(400).json({ error: "Invalid username" });
    return;
  }
  
  if (!password) {
    res.status(400).json({ error: "Password too short" });
    return;
  }
  
  if (!validatePassword(password)) {
    res.status(400).json({ error: "Password too short" });
    return;
  }
  
  // Check if username is unique
  const existingUser = users.find(user => user.username === username);
  if (existingUser) {
    res.status(409).json({ error: "Username already exists" });
    return;
  }
  
  // Create new user
  const newUser: User = {
    id: nextUserId++,
    username: username,
    password: password  // Note: in production, passwords should be hashed
  };
  
  users.push(newUser);
  
  res.status(201).json({
    id: newUser.id,
    username: newUser.username
  });
});

app.post('/login', (req: Request, res: Response): void => {
  const { username, password } = req.body;
  
  // Find user
  const user = users.find(u => u.username === username);
  
  if (!user || user.password !== password) {
    res.status(401).json({ error: "Invalid credentials" });
    return;
  }
  
  // Generate session
  const sessionId = generateSessionId();
  sessions.set(sessionId, user.id);
  
  // Set cookie and send response
  res.cookie('session_id', sessionId, { 
    httpOnly: true, 
    path: '/' 
  });
  
  res.status(200).json({
    id: user.id,
    username: user.username
  });
});

app.post('/logout', authenticate, (req: Request, res: Response): void => {
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  
  if (sessionId) {
    sessions.delete(sessionId);
  }
  
  res.status(200).json({});
});

app.get('/me', authenticate, (req: Request, res: Response): void => {
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  const userId = sessionId ? sessions.get(sessionId) : undefined;
  
  if (userId === undefined) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  const user = users.find(u => u.id === userId);
  if (!user) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  res.status(200).json({
    id: user.id,
    username: user.username
  });
});

app.put('/password', authenticate, (req: Request, res: Response): void => {
  const { old_password, new_password } = req.body;
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  const userId = sessionId ? sessions.get(sessionId) : undefined;
  
  if (!userId) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  // Find the user in the array by reference so we can update their password
  const userIndex = users.findIndex(u => u.id === userId);
  if (userIndex === -1) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  // Verify old password
  if (users[userIndex].password !== old_password) {
    res.status(401).json({ error: "Invalid credentials" });
    return;
  }

  // Validate new password
  if (!new_password || new_password.length < 8) {
    res.status(400).json({ error: "Password too short" });
    return;
  }

  // Update the stored password
  users[userIndex].password = new_password;
  res.status(200).json({});
});

app.get('/todos', authenticate, (req: Request, res: Response): void => {
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  const userId = sessionId ? sessions.get(sessionId) : undefined;
  
  if (userId === undefined) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  const userTodos = todos.filter(todo => todo.userId === userId);
  res.status(200).json(userTodos);
});

app.post('/todos', authenticate, (req: Request, res: Response): void => {
  const { title, description } = req.body;
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  const userId = sessionId ? sessions.get(sessionId) : undefined;
  
  if (userId === undefined) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  // Validate title
  if (!title || title.trim() === "") {
    res.status(400).json({ error: "Title is required" });
    return;
  }
  
  const createdAt = getTimestamp();
  
  const newTodo: Todo = {
    id: nextTodoId++,
    title: title,
    description: description || "",
    completed: false,
    created_at: createdAt,
    updated_at: createdAt,
    userId: userId
  };
  
  todos.push(newTodo);
  
  res.status(201).json(newTodo);
});

app.get('/todos/:id', authenticate, (req: Request, res: Response): void => {
  const todoId = parseInt(req.params.id, 10);
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  const userId = sessionId ? sessions.get(sessionId) : undefined;
  
  if (userId === undefined || Number.isNaN(todoId)) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  const todo = todos.find(t => t.id === todoId);
  
  if (!todo || todo.userId !== userId) {
    res.status(404).json({ error: "Todo not found" });
    return;
  }
  
  res.status(200).json(todo);
});

app.put('/todos/:id', authenticate, (req: Request, res: Response): void => {
  const todoId = parseInt(req.params.id, 10);
  const { title, description, completed } = req.body;
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  const userId = sessionId ? sessions.get(sessionId) : undefined;
  
  if (userId === undefined || Number.isNaN(todoId)) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === userId);
  
  if (todoIndex === -1) {
    res.status(404).json({ error: "Todo not found" });
    return;
  }
  
  // Validate title if provided
  if (title !== undefined && title.trim() === "") {
    res.status(400).json({ error: "Title is required" });
    return;
  }
  
  // Update fields that were provided
  if (title !== undefined) {
    todos[todoIndex].title = title;
  }
  if (description !== undefined) {
    todos[todoIndex].description = description;
  }
  if (completed !== undefined) {
    todos[todoIndex].completed = completed;
  }
  
  // Update timestamp
  todos[todoIndex].updated_at = getTimestamp();
  
  res.status(200).json(todos[todoIndex]);
});

app.delete('/todos/:id', authenticate, (req: Request, res: Response): void => {
  const todoId = parseInt(req.params.id, 10);
  const sessionId = req.cookies?.session_id || req.headers.cookie?.match(/session_id=([^;]+)/)?.[1];
  const userId = sessionId ? sessions.get(sessionId) : undefined;
  
  if (userId === undefined || Number.isNaN(todoId)) {
    res.status(401).json({ error: "Authentication required" });
    return;
  }
  
  const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === userId);
  
  if (todoIndex === -1) {
    res.status(404).json({ error: "Todo not found" });
    return;
  }
  
  todos.splice(todoIndex, 1);
  
  res.status(204).send();
});

export default app;