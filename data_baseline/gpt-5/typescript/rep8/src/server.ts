import express, { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';

// Types
interface User {
  id: number;
  username: string;
  password: string; // stored in plain for simplicity (in-memory only). In real-life, hash it.
}

interface Todo {
  id: number;
  userId: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
}

// In-memory stores
const users: User[] = [];
const sessions = new Map<string, number>(); // session_id -> userId
const todos: Todo[] = [];
let nextUserId = 1;
let nextTodoId = 1;

// Helpers
function nowIsoSecond(): string {
  const d = new Date();
  // toISOString has milliseconds. We need seconds precision.
  const iso = d.toISOString();
  return iso.replace(/\..+Z$/, 'Z');
}

function isValidUsername(u: any): u is string {
  if (typeof u !== 'string') return false;
  if (u.length < 3 || u.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(u)) return false;
  return true;
}

function parsePortArg(argv: string[]): number | null {
  const idx = argv.indexOf('--port');
  if (idx !== -1 && argv[idx + 1]) {
    const p = Number(argv[idx + 1]);
    if (Number.isInteger(p) && p > 0 && p < 65536) return p;
  }
  return null;
}

function setJsonContentType(req: Request, res: Response, next: NextFunction) {
  // For all responses except DELETE with 204, we ensure JSON content-type.
  // We'll set header for all routes; DELETE handlers will end without body.
  res.setHeader('Content-Type', 'application/json');
  next();
}

function getSessionUserId(req: Request): number | null {
  const cookieHeader = req.headers['cookie'];
  if (!cookieHeader) return null;
  const cookies = Object.fromEntries(cookieHeader.split(';').map(p => {
    const [k, ...rest] = p.trim().split('=');
    return [k, rest.join('=')];
  }));
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = sessions.get(token);
  return userId ?? null;
}

function authRequired(req: Request, res: Response, next: NextFunction) {
  const uid = getSessionUserId(req);
  if (!uid) {
    res.status(401).json({ error: 'Authentication required' });
    return;
  }
  (req as any).userId = uid;
  next();
}

function sanitizeTodoOutput(todo: Todo): Omit<Todo, 'userId'> {
  const { userId, ...rest } = todo;
  return rest;
}

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '100kb' }));
app.use(setJsonContentType);

// Routes
// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (!isValidUsername(username)) {
    res.status(400).json({ error: 'Invalid username' });
    return;
  }
  if (typeof password !== 'string' || password.length < 8) {
    res.status(400).json({ error: 'Password too short' });
    return;
  }
  const exists = users.some(u => u.username.toLowerCase() === username.toLowerCase());
  if (exists) {
    res.status(409).json({ error: 'Username already exists' });
    return;
  }
  const user: User = { id: nextUserId++, username, password };
  users.push(user);
  res.status(201).json({ id: user.id, username: user.username });
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || typeof password !== 'string') {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  const user = users.find(u => u.username === username);
  if (!user || user.password !== password) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  const token = crypto.randomUUID().replace(/-/g, '');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.status(200).json({ id: user.id, username: user.username });
});

// POST /logout
app.post('/logout', authRequired, (req: Request, res: Response) => {
  const cookieHeader = req.headers['cookie'];
  if (cookieHeader) {
    const cookies = Object.fromEntries(cookieHeader.split(';').map(p => {
      const [k, ...rest] = p.trim().split('=');
      return [k, rest.join('=')];
    }));
    const token = cookies['session_id'];
    if (token) {
      sessions.delete(token);
    }
  }
  res.status(200).json({});
});

// GET /me
app.get('/me', authRequired, (req: Request, res: Response) => {
  const uid: number = (req as any).userId;
  const user = users.find(u => u.id === uid);
  if (!user) {
    // Session exists but user missing; treat as unauthenticated for safety
    res.status(401).json({ error: 'Authentication required' });
    return;
  }
  res.status(200).json({ id: user.id, username: user.username });
});

// PUT /password
app.put('/password', authRequired, (req: Request, res: Response) => {
  const uid: number = (req as any).userId;
  const { old_password, new_password } = req.body || {};
  const user = users.find(u => u.id === uid)!;
  if (typeof old_password !== 'string' || user.password !== old_password) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    res.status(400).json({ error: 'Password too short' });
    return;
  }
  user.password = new_password;
  res.status(200).json({});
});

// GET /todos
app.get('/todos', authRequired, (req: Request, res: Response) => {
  const uid: number = (req as any).userId;
  const list = todos.filter(t => t.userId === uid).sort((a, b) => a.id - b.id).map(sanitizeTodoOutput);
  res.status(200).json(list);
});

// POST /todos
app.post('/todos', authRequired, (req: Request, res: Response) => {
  const uid: number = (req as any).userId;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    res.status(400).json({ error: 'Title is required' });
    return;
  }
  const desc = typeof description === 'string' ? description : '';
  const timestamp = nowIsoSecond();
  const todo: Todo = {
    id: nextTodoId++,
    userId: uid,
    title,
    description: desc,
    completed: false,
    created_at: timestamp,
    updated_at: timestamp,
  };
  todos.push(todo);
  res.status(201).json(sanitizeTodoOutput(todo));
});

function findUserTodo(uid: number, idStr: string): Todo | null {
  const id = Number(idStr);
  if (!Number.isInteger(id) || id <= 0) return null;
  const todo = todos.find(t => t.id === id && t.userId === uid);
  return todo || null;
}

// GET /todos/:id
app.get('/todos/:id', authRequired, (req: Request, res: Response) => {
  const uid: number = (req as any).userId;
  const todo = findUserTodo(uid, req.params.id);
  if (!todo) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  res.status(200).json(sanitizeTodoOutput(todo));
});

// PUT /todos/:id
app.put('/todos/:id', authRequired, (req: Request, res: Response) => {
  const uid: number = (req as any).userId;
  const todo = findUserTodo(uid, req.params.id);
  if (!todo) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      res.status(400).json({ error: 'Title is required' });
      return;
    }
    todo.title = title;
  }
  if (description !== undefined) {
    if (typeof description !== 'string') {
      res.status(400).json({ error: 'Invalid request' });
      return;
    }
    todo.description = description;
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      res.status(400).json({ error: 'Invalid request' });
      return;
    }
    todo.completed = completed;
  }
  todo.updated_at = nowIsoSecond();
  res.status(200).json(sanitizeTodoOutput(todo));
});

// DELETE /todos/:id
app.delete('/todos/:id', authRequired, (req: Request, res: Response) => {
  const uid: number = (req as any).userId;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  const idx = todos.findIndex(t => t.id === id && t.userId === uid);
  if (idx === -1) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  todos.splice(idx, 1);
  // For DELETE, must return 204 with no body
  res.status(204).end();
});

// Error handler to ensure JSON content type for errors not caught
app.use((err: any, req: Request, res: Response, next: NextFunction) => {
  try {
    if (!res.headersSent) {
      res.setHeader('Content-Type', 'application/json');
      res.status(500).json({ error: 'Internal server error' });
    } else {
      next(err);
    }
  } catch {
    next(err);
  }
});

// Start server
const port = parsePortArg(process.argv) ?? 3000;
app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
