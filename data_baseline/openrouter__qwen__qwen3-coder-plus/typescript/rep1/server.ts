import express, { Request, Response } from 'express';
import crypto from 'crypto';
import { body, validationResult, param } from 'express-validator';
import cookieParser from 'cookie-parser';
import cors from 'cors';

// Augment Express Request type
declare global {
  namespace Express {
    interface Request {
      userId?: number;
    }
  }
}

interface User {
  id: number;
  username: string;
  passwordHash: string; // For real applications, this would be a hash
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

// In-memory storage
let users: User[] = [];
let todos: Todo[] = [];
let nextUserId = 1;
let nextTodoId = 1;

// Simple password store (not secure in practice)
const passwords: Map<number, string> = new Map();
const sessions: Map<string, number> = new Map(); // sessionId -> userId mapping

const app = express();

app.use(cors());
app.use(express.json());
app.use(cookieParser());

// Middleware to authenticate requests based on session_id cookie
const authenticateUser = (req: Request, res: Response, next: Function) => {
  const sessionId = req.cookies?.session_id;

  if (!sessionId || !sessions.has(sessionId)) {
    return res.status(401).json({ error: "Authentication required" });
  }

  // Add userId to request object if authenticated
  req.userId = sessions.get(sessionId);
  return next();
};

// Validation middleware helper
const validate = (validations: any[]) => {
  return async (req: Request, res: Response, next: Function) => {
    await Promise.all(validations.map(validation => validation.run(req)));

    const errors = validationResult(req);
    if (errors.isEmpty()) {
      return next();
    }

    return res.status(400).json({ 
      error: errors.array()[0].msg 
    });
  };
};

// POST /register
app.post(
  '/register',
  [
    body('username')
      .notEmpty()
      .withMessage('Username is required')
      .isLength({ min: 3, max: 50 })
      .withMessage('Username must be between 3 and 50 characters')
      .matches(/^[a-zA-Z0-9_]+$/)
      .withMessage('Invalid username'),
    body('password')
      .isLength({ min: 8 })
      .withMessage('Password too short')
  ],
  validate([
    body('username').notEmpty(),
    body('password').isLength({ min: 8 })
  ]),
  (req: Request, res: Response) => {
    const { username, password } = req.body;

    // Check if username already exists
    const existingUser = users.find(u => u.username === username);
    
    if (existingUser) {
      return res.status(409).json({ error: "Username already exists" });
    }
    
    // Create new user
    const user: User = {
      id: nextUserId++,
      username,
      passwordHash: password // In a real app, use bcrypt to hash
    };
    
    users.push(user);
    passwords.set(user.id, password); // Store password
    
    // Return user info
    const { id, username: userUsername } = user;
    res.status(201).json({ id, username: userUsername });
  }
);

// POST /login
app.post(
  '/login',
  [
    body('username').notEmpty().withMessage('Username is required'),
    body('password').notEmpty().withMessage('Password is required')
  ],
  validate([
    body('username').notEmpty(),
    body('password').notEmpty()
  ]),
  (req: Request, res: Response) => {
    const { username, password } = req.body;

    // Find user by username
    const user = users.find(u => u.username === username);
    
    if (!user || passwords.get(user.id) !== password) {
      return res.status(401).json({ error: "Invalid credentials" });
    }
    
    // Create session
    const sessionId = crypto.randomUUID();
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
  }
);

// POST /logout
app.post('/logout', authenticateUser, (req: Request, res: Response) => {
  const sessionId = req.cookies?.session_id;
  
  if (sessionId && sessions.has(sessionId)) {
    sessions.delete(sessionId);
  }
  
  res.status(200).json({});
});

// GET /me
app.get('/me', authenticateUser, (req: Request, res: Response) => {
  const userId = req.userId!;
  const user = users.find(u => u.id === userId);
  
  if (!user) {
    return res.status(401).json({ error: "Authentication required" });
  }
  
  const { id, username } = user;
  res.status(200).json({ id, username });
});

// PUT /password
app.put(
  '/password',
  authenticateUser,
  [
    body('old_password')
      .notEmpty()
      .withMessage('Old password is required'),
    body('new_password')
      .isLength({ min: 8 })
      .withMessage('Password too short')
  ],
  validate([
    body('old_password').notEmpty(),
    body('new_password').isLength({ min: 8 })
  ]),
  (req: Request, res: Response) => {
    const userId = req.userId!;
    const { old_password, new_password } = req.body;
    
    const currentPassword = passwords.get(userId);
    
    if (currentPassword !== old_password) {
      return res.status(401).json({ error: "Invalid credentials" });
    }
    
    // Update password
    passwords.set(userId, new_password);
    // Also update the passwordHash in user object for consistency
    const userIdx = users.findIndex(u => u.id === userId);
    if (userIdx >= 0) {
      users[userIdx].passwordHash = new_password;
    }
    
    res.status(200).json({});
  }
);

// GET /todos
app.get('/todos', authenticateUser, (req: Request, res: Response) => {
  const userId = req.userId!;
  
  const userTodos = todos.filter(todo => todo.userId === userId);
  res.status(200).json(userTodos);
});

// POST /todos
app.post(
  '/todos',
  authenticateUser,
  [
    body('title')
      .notEmpty()
      .withMessage('Title is required')
  ],
  validate([
    body('title').notEmpty()
  ]),
  (req: Request, res: Response) => {
    const userId = req.userId!;
    const { title, description = "" } = req.body;
    
    const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    
    const todo: Todo = {
      id: nextTodoId++,
      title,
      description,
      completed: false,
      created_at: now,
      updated_at: now,
      userId
    };
    
    todos.push(todo);
    res.status(201).json(todo);
  }
);

// GET /todos/:id
app.get(
  '/todos/:id',
  authenticateUser,
  [
    param('id').isInt({ min: 1 }).withMessage('ID must be a positive integer')
  ],
  validate([
    param('id').isInt({ min: 1 })
  ]),
  (req: Request, res: Response) => {
    const userId = req.userId!;
    const todoId = parseInt(req.params.id, 10);
    
    const todo = todos.find(t => t.id === todoId && t.userId === userId);
    
    if (!todo) {
      return res.status(404).json({ error: "Todo not found" });
    }
    
    res.status(200).json(todo);
  }
);

// PUT /todos/:id
app.put(
  '/todos/:id',
  authenticateUser,
  [
    param('id').isInt({ min: 1 }).withMessage('ID must be a positive integer'),
    body('title')
      .optional()
      .notEmpty()
      .withMessage('Title is required')
  ],
  validate([
    param('id').isInt({ min: 1 }),
    body('title')
      .optional()
      .notEmpty()
  ]),
  (req: Request, res: Response) => {
    const userId = req.userId!;
    const todoId = parseInt(req.params.id, 10);
    
    const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === userId);
    
    if (todoIndex === -1) {
      return res.status(404).json({ error: "Todo not found" });
    }
    
    // Get existing todo
    let todo = { ...todos[todoIndex] };
    
    // Partial update - only modify provided fields
    if ('title' in req.body) todo.title = req.body.title;
    if ('description' in req.body) todo.description = req.body.description;
    if ('completed' in req.body) todo.completed = req.body.completed;
    
    // Always update the updated_at timestamp
    todo.updated_at = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    
    // Replace the todo
    todos[todoIndex] = todo;
    
    res.status(200).json(todo);
  }
);

// DELETE /todos/:id
app.delete(
  '/todos/:id',
  authenticateUser,
  [
    param('id').isInt({ min: 1 }).withMessage('ID must be a positive integer')
  ],
  validate([
    param('id').isInt({ min: 1 })
  ]),
  (req: Request, res: Response) => {
    const userId = req.userId!;
    const todoId = parseInt(req.params.id, 10);
    
    const todoIndex = todos.findIndex(t => t.id === todoId && t.userId === userId);
    
    if (todoIndex === -1) {
      return res.status(404).json({ error: "Todo not found" });
    }
    
    // Remove the todo
    todos.splice(todoIndex, 1);
    res.status(204).send();
  }
);

export default app;