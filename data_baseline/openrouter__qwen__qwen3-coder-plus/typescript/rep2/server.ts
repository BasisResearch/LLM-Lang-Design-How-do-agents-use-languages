import express, { Request, Response } from 'express';
import bcrypt from 'bcryptjs';
import { v4 as uuidv4 } from 'uuid';
import cookieParser from 'cookie-parser';

// In-memory storage
const users: User[] = [];
let nextUserId = 1;

const todos: Todo[] = [];
let nextTodoId = 1;

// Session management (in-memory for now)
const activeSessions: Map<string, number> = new Map(); // Maps session ID to user ID

interface User {
  id: number;
  username: string;
  passwordHash: string; // hashed password
}

interface Todo {
  id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
  userId: number; // ID of the user who owns this todo
}

const app = express();
app.use(express.json());
app.use(cookieParser());

// Helper function for generating timestamps in required format (YYYY-MM-DDTHH:MM:SSZ)
function getISODateString(): string {
  const date = new Date();
  // Ensure seconds precision by zeroing milliseconds
  date.setMilliseconds(0);
  return date.toISOString().replace(/\.\d{3}/, '');
}

// Helper middleware to authenticate requests based on session cookie
function authenticate(req: Request, res: Response, next: () => void) {
  const sessionId = req.cookies?.session_id;
  
  if (!sessionId || !activeSessions.has(sessionId)) {
    return res.status(401).json({ error: "Authentication required" });
  }

  next();
}

// Helper function to ensure titles are valid
function isValidTitle(title: string | undefined): boolean {
  return title !== undefined && typeof title === 'string' && title.trim().length > 0;
}

// Endpoint implementations:

// POST /register
app.post('/register', async (req, res) => {
  const { username, password } = req.body;

  // Validation
  if (!username) {
    return res.status(400).json({ error: "Username is required" });
  }

  if (typeof username !== 'string' || !/^[a-zA-Z0-9_]+$/.test(username) || username.length < 3 || username.length > 50) {
    return res.status(400).json({ error: "Invalid username" });
  }

  if (!password) {
    return res.status(400).json({ error: "Password is required" });
  }

  if (typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  // Check if username already exists
  if (users.some(user => user.username === username)) {
    return res.status(409).json({ error: "Username already exists" });
  }

  // Hash password
  const saltRounds = 10;
  const passwordHash = await bcrypt.hash(password, saltRounds);

  // Create new user
  const newUser: User = {
    id: nextUserId++,
    username,
    passwordHash
  };

  users.push(newUser);

  res.status(201).json({
    id: newUser.id,
    username: newUser.username
  });
});

// POST /login
app.post('/login', async (req, res) => {
  const { username, password } = req.body;

  // Find user
  const user = users.find(u => u.username === username);
  
  if (!user || !await bcrypt.compare(password, user.passwordHash)) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  // Create new session
  const sessionId = uuidv4();
  activeSessions.set(sessionId, user.id);

  // Send response with Set-Cookie header
  res.cookie('session_id', sessionId, { 
    httpOnly: true, 
    path: '/' 
  });

  res.status(200).json({
    id: user.id,
    username: user.username
  });
});

// POST /logout
app.post('/logout', authenticate, (req, res) => {
  const sessionId = req.cookies.session_id;
  
  if (sessionId) {
    // Remove session server-side
    activeSessions.delete(sessionId);
  }

  res.status(200).json({});
});

// GET /me
app.get('/me', authenticate, (req, res) => {
  const sessionId = req.cookies.session_id;
  
  if (!sessionId) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const userId = activeSessions.get(sessionId);
  const user = users.find(u => u.id === userId);

  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }

  res.status(200).json({
    id: user.id,
    username: user.username
  });
});

// PUT /password
app.put('/password', authenticate, async (req, res) => {
  const { old_password, new_password } = req.body;
  const sessionId = req.cookies.session_id;
  
  if (!sessionId) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const userId = activeSessions.get(sessionId)!;
  const user = users.find(u => u.id === userId);
  
  if (!old_password) {
    return res.status(400).json({ error: "Old password is required" });
  }

  if (!new_password) {
    return res.status(400).json({ error: "New password is required" });
  }

  if (!await bcrypt.compare(old_password, user!.passwordHash)) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  if (typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  // Hash new password and update user
  const newPasswordHash = await bcrypt.hash(new_password, 10);
  user!.passwordHash = newPasswordHash;

  res.status(200).json({});
});

// GET /todos
app.get('/todos', authenticate, (req, res) => {
  const sessionId = req.cookies.session_id;
  
  if (!sessionId) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const userId = activeSessions.get(sessionId)!;
  
  const userTodos = todos
    .filter(todo => todo.userId === userId)
    .sort((a, b) => a.id - b.id); // Ordered by id ascending
  
  res.status(200).json(userTodos);
});

// POST /todos
app.post('/todos', authenticate, (req, res) => {
  const { title, description } = req.body;
  const sessionId = req.cookies.session_id;
  
  if (!sessionId) {
    return res.status(401).json({ error: "Authentication required" });
  }

  if (!isValidTitle(title)) {
    return res.status(400).json({ error: "Title is required" });
  }

  const userId = activeSessions.get(sessionId)!;

  const createdAt = getISODateString();
  const updatedAt = createdAt;

  const newTodo: Todo = {
    id: nextTodoId++,
    title: title.trim(),
    description: description ? description.toString() : "",
    completed: false,
    created_at: createdAt,
    updated_at: updatedAt,
    userId
  };

  todos.push(newTodo);

  res.status(201).json(newTodo);
});

// GET /todos/:id
app.get('/todos/:id', authenticate, (req, res) => {
  const todoId = parseInt(req.params.id);
  const sessionId = req.cookies.session_id;
  
  if (!sessionId) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const userId = activeSessions.get(sessionId)!;

  const todo = todos.find(t => t.id === todoId && t.userId === userId);

  if (!todo) {
    return res.status(404).json({ error: "Todo not found" });
  }

  res.status(200).json(todo);
});

// PUT /todos/:id
app.put('/todos/:id', authenticate, (req, res) => {
  const todoId = parseInt(req.params.id);
  const { title, description, completed } = req.body;
  const sessionId = req.cookies.session_id;
  
  if (!sessionId) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const userId = activeSessions.get(sessionId)!;
  const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === userId);

  if (todoIndex === -1) {
    return res.status(404).json({ error: "Todo not found" });
  }

  // Validate title if provided
  if (title !== undefined && !isValidTitle(title)) {
    return res.status(400).json({ error: "Title is required" });
  }

  // Update the todo
  const updatedTodo = { ...todos[todoIndex] };
  
  if (title !== undefined) updatedTodo.title = title.trim();
  if (description !== undefined) updatedTodo.description = description.toString();
  if (completed !== undefined) updatedTodo.completed = completed;
  
  updatedTodo.updated_at = getISODateString();
  
  // Replace the todo in the array
  todos[todoIndex] = updatedTodo;

  res.status(200).json(updatedTodo);
});

// DELETE /todos/:id
app.delete('/todos/:id', authenticate, (req, res) => {
  const todoId = parseInt(req.params.id);
  const sessionId = req.cookies.session_id;
  
  if (!sessionId) {
    return res.status(401).json({ error: "Authentication required" });
  }

  const userId = activeSessions.get(sessionId)!;
  const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === userId);

  if (todoIndex === -1) {
    return res.status(404).json({ error: "Todo not found" });
  }

  // Remove the todo
  todos.splice(todoIndex, 1);

  res.sendStatus(204);
});

// Handle errors globally - fixed the middleware signature
app.use((err: Error, req: Request, res: Response, next: () => void) => {
  console.error(err.stack);
  res.status(500).json({ error: "Internal server error" });
});

// CLI argument processing
const args = process.argv.slice(2);
let port = 3000;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && args[i + 1]) {
    port = parseInt(args[i + 1]);
    i++;  // Skip the next argument since it's the port value
  }
}

app.listen(port, '0.0.0.0', () => {
  console.log(`Server running on 0.0.0.0:${port}`);
});