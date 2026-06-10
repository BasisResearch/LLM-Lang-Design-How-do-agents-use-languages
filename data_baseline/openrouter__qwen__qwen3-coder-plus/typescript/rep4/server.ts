import express, { Request, Response, NextFunction } from 'express';
import bodyParser from 'body-parser';
import { v4 as uuidv4 } from 'uuid';

// In-memory storage
const users: Map<number, { id: number; username: string; password: string }> = new Map();
const todos: Map<number, { id: number; userId: number; title: string; description: string; completed: boolean; created_at: string; updated_at: string }> = new Map();
const sessions: Map<string, number> = new Map(); // Map session_id to user_id

let userIdCounter = 1;
let todoIdCounter = 1;

// Utility function to validate usernames
function isValidUsername(username: string): boolean {
  return /^[a-zA-Z0-9_]+$/.test(username) && username.length >= 3 && username.length <= 50;
}

// Utility function to validate date format (ISO 8601 with second precision)
function getCurrentTimestamp(): string {
  const now = new Date();
  // Format to YYYY-MM-DDTHH:MM:SSZ with zero-padding
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');
  const hours = String(now.getUTCHours()).padStart(2, '0');
  const minutes = String(now.getUTCMinutes()).padStart(2, '0');
  const seconds = String(now.getUTCSeconds()).padStart(2, '0');
  
  return `${year}-${month}-${day}T${hours}:${minutes}:${seconds}Z`;
}

// Middleware to authenticate requests using session cookie
function authenticate(req: Request, res: Response, next: NextFunction) {
  const sessionId = req.cookies?.session_id;
  
  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: "Authentication required" });
  }
  
  // Attach the authenticated user ID to the request object
  req.userId = sessions.get(sessionId)!;
  next();
}

// Helper function to get all todos for a specific user
function getUserTodos(userId: number) {
  const userTodos: Array<{ id: number; userId: number; title: string; description: string; completed: boolean; created_at: string; updated_at: string }> = [];
  
  for (const [_, todo] of todos) {
    if (todo.userId === userId) {
      userTodos.push(todo);
    }
  }
  
  return userTodos.sort((a, b) => a.id - b.id); // Sort by ID ascending
}

// Define the extended Request interface to include userId
interface AuthenticatedRequest extends Request {
  userId: number;
}

const app = express();

// Middleware
app.use(bodyParser.json());

// Custom middleware to parse cookies
app.use((req, res, next) => {
  if (req.headers.cookie) {
    const cookies: { [key: string]: string } = {};
    req.headers.cookie.split(';').forEach(cookie => {
      const parts = cookie.trim().split('=');
      if (parts.length === 2) {
        cookies[parts[0]] = parts[1];
      }
    });
    req.cookies = cookies;
  } else {
    req.cookies = {};
  }
  next();
});

// Routes
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body;

  // Validate input
  if (!username) {
    return res.status(400).json({ error: "Invalid username" });
  }

  if (!isValidUsername(username)) {
    return res.status(400).json({ error: "Invalid username" });
  }

  if (!password || password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  // Check if username already exists
  for (const [_, user] of users) {
    if (user.username === username) {
      return res.status(409).json({ error: "Username already exists" });
    }
  }

  // Create new user
  const newUser = {
    id: userIdCounter++,
    username,
    password  // In real applications, store hashed passwords!
  };

  users.set(newUser.id, newUser);
  
  res.status(201).json({
    id: newUser.id,
    username: newUser.username
  });
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body;

  let foundUser = null;
  for (const [_, user] of users) {
    if (user.username === username && user.password === password) {
      foundUser = user;
      break;
    }
  }

  if (!foundUser) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  // Generate a session token
  const sessionId = uuidv4();
  sessions.set(sessionId, foundUser.id);

  // Set the session cookie
  res.setHeader('Set-Cookie', `session_id=${sessionId}; Path=/; HttpOnly`);
  
  res.status(200).json({
    id: foundUser.id,
    username: foundUser.username
  });
});

app.post('/logout', authenticate, (req: AuthenticatedRequest, res: Response) => {
  const sessionId = req.cookies?.session_id;
  
  if (sessionId) {
    sessions.delete(sessionId);
  }
  
  res.status(200).json({});
});

app.get('/me', authenticate, (req: AuthenticatedRequest, res: Response) => {
  const user = users.get(req.userId);
  
  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }
  
  res.status(200).json({
    id: user.id,
    username: user.username
  });
});

app.put('/password', authenticate, (req: AuthenticatedRequest, res: Response) => {
  const { old_password, new_password } = req.body;

  const user = users.get(req.userId);
  
  if (!user || user.password !== old_password) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  if (!new_password || new_password.length < 8) {
    return res.status(400).json({ error: "Password too short" });
  }

  // Update password
  user.password = new_password;
  users.set(user.id, user);
  
  res.status(200).json({});
});

app.get('/todos', authenticate, (req: AuthenticatedRequest, res: Response) => {
  const userTodos = getUserTodos(req.userId);
  res.status(200).json(userTodos);
});

app.post('/todos', authenticate, (req: AuthenticatedRequest, res: Response) => {
  const { title, description } = req.body;

  if (!title || title.trim() === '') {
    return res.status(400).json({ error: "Title is required" });
  }

  const timestamp = getCurrentTimestamp();
  const newTodo = {
    id: todoIdCounter++,
    userId: req.userId,
    title,
    description: description || "",
    completed: false,
    created_at: timestamp,
    updated_at: timestamp
  };

  todos.set(newTodo.id, newTodo);
  
  res.status(201).json(newTodo);
});

app.get('/todos/:id', authenticate, (req: AuthenticatedRequest, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  
  if (isNaN(todoId)) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const todo = todos.get(todoId);
  
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  res.status(200).json(todo);
});

app.put('/todos/:id', authenticate, (req: AuthenticatedRequest, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  const updates = req.body;
  
  if (isNaN(todoId)) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const todo = todos.get(todoId);
  
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  // Validate if title is present and empty
  if ('title' in updates && (typeof updates.title !== 'string' || updates.title.trim() === '')) {
    return res.status(400).json({ error: "Title is required" });
  }

  // Apply updates - only update fields that are provided
  if ('title' in updates && typeof updates.title === 'string') {
    todo.title = updates.title.trim();
  }
  if ('description' in updates && typeof updates.description === 'string') {
    todo.description = updates.description;
  }
  if ('completed' in updates && typeof updates.completed === 'boolean') {
    todo.completed = updates.completed;
  }
  
  // Update the timestamp
  todo.updated_at = getCurrentTimestamp();
  
  todos.set(todoId, todo);
  
  res.status(200).json(todo);
});

app.delete('/todos/:id', authenticate, (req: AuthenticatedRequest, res: Response) => {
  const todoId = parseInt(req.params.id, 10);
  
  if (isNaN(todoId)) {
    return res.status(404).json({ error: "Todo not found" });
  }

  const todo = todos.get(todoId);
  
  if (!todo || todo.userId !== req.userId) {
    return res.status(404).json({ error: "Todo not found" });
  }

  todos.delete(todoId);
  res.status(204).send(); // 204 No Content for successful deletion
});

// Global error handler middleware
app.use((err: any, req: Request, res: Response, next: NextFunction) => {
  console.error(err.stack);
  res.status(500).json({ error: "Internal server error" });
});

export default app;

// Only run the server if this script is executed directly
if (require.main === module) {
  const args = process.argv.slice(2);
  let port = 3000; // Default port

  // Parse command-line arguments
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
      port = parseInt(args[i + 1], 10);
      break;
    }
  }

  app.listen(port, '0.0.0.0', () => {
    console.log(`Server running on http://0.0.0.0:${port}`);
  });
}