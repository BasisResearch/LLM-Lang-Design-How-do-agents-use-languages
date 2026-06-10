import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { v4 as uuidv4 } from 'uuid';

// Types
interface User {
  id: number;
  username: string;
  password: string; // stored in memory as plain for simplicity per spec (no persistence)
}

interface PublicUser {
  id: number;
  username: string;
}

interface Todo {
  id: number;
  user_id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string;
  updated_at: string;
}

// In-memory stores
const users: User[] = [];
const usernameToId = new Map<string, number>();
let nextUserId = 1;

const todos: Todo[] = [];
let nextTodoId = 1;

// session_id -> userId
const sessions = new Map<string, number>();

// Helpers
function jsonTimeNow(): string {
  // ISO 8601 UTC with seconds precision
  const d = new Date();
  const iso = d.toISOString(); // e.g., 2025-01-15T09:30:00.123Z
  return iso.replace(/\..*Z$/, 'Z'); // strip milliseconds
}

function toPublicUser(u: User): PublicUser {
  return { id: u.id, username: u.username };
}

function setJson(res: Response): Response {
  res.setHeader('Content-Type', 'application/json');
  return res;
}

// Middleware to ensure JSON content-type on all responses except DELETE success with 204
const app = express();
app.use(express.json());
app.use(cookieParser());

// Auth middleware
function requireAuth(req: Request, res: Response, next: NextFunction) {
  const token = req.cookies?.session_id as string | undefined;
  if (!token) {
    return setJson(res).status(401).json({ error: 'Authentication required' });
  }
  const userId = sessions.get(token);
  if (!userId) {
    return setJson(res).status(401).json({ error: 'Authentication required' });
  }
  const user = users.find(u => u.id === userId);
  if (!user) {
    // Should not happen, but treat as unauthenticated and invalidate
    sessions.delete(token);
    return setJson(res).status(401).json({ error: 'Authentication required' });
  }
  (req as any).user = user;
  (req as any).sessionToken = token;
  next();
}

// Validators
const USERNAME_RE = /^[a-zA-Z0-9_]{3,50}$/;

// Routes

// POST /register
app.post('/register', (req: Request, res: Response) => {
  setJson(res);
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || !USERNAME_RE.test(username)) {
    return res.status(400).json({ error: 'Invalid username' });
  }
  if (typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  if (usernameToId.has(username)) {
    return res.status(409).json({ error: 'Username already exists' });
  }
  const user: User = { id: nextUserId++, username, password };
  users.push(user);
  usernameToId.set(username, user.id);
  return res.status(201).json(toPublicUser(user));
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  setJson(res);
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || typeof password !== 'string') {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  const userId = usernameToId.get(username);
  if (!userId) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  const user = users.find(u => u.id === userId);
  if (!user || user.password !== password) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  // create session
  const token = uuidv4().replace(/-/g, '');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  return res.status(200).json(toPublicUser(user));
});

// POST /logout
app.post('/logout', requireAuth, (req: Request, res: Response) => {
  setJson(res);
  const token = (req as any).sessionToken as string;
  if (token) {
    sessions.delete(token);
  }
  return res.status(200).json({});
});

// GET /me
app.get('/me', requireAuth, (req: Request, res: Response) => {
  setJson(res);
  const user = (req as any).user as User;
  return res.status(200).json(toPublicUser(user));
});

// PUT /password
app.put('/password', requireAuth, (req: Request, res: Response) => {
  setJson(res);
  const user = (req as any).user as User;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || user.password !== old_password) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  user.password = new_password;
  return res.status(200).json({});
});

// GET /todos
app.get('/todos', requireAuth, (req: Request, res: Response) => {
  setJson(res);
  const user = (req as any).user as User;
  const list = todos.filter(t => t.user_id === user.id).sort((a,b) => a.id - b.id);
  return res.status(200).json(list.map(publicTodo));
});

function publicTodo(t: Todo) {
  // all fields except user_id
  const { id, title, description, completed, created_at, updated_at } = t;
  return { id, title, description, completed, created_at, updated_at };
}

// POST /todos
app.post('/todos', requireAuth, (req: Request, res: Response) => {
  setJson(res);
  const user = (req as any).user as User;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return res.status(400).json({ error: 'Title is required' });
  }
  const now = jsonTimeNow();
  const todo: Todo = {
    id: nextTodoId++,
    user_id: user.id,
    title: title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.push(todo);
  return res.status(201).json(publicTodo(todo));
});

function findOwnTodo(userId: number, idParam: string): Todo | undefined {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) return undefined;
  const t = todos.find(td => td.id === id && td.user_id === userId);
  return t;
}

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  setJson(res);
  const user = (req as any).user as User;
  const t = findOwnTodo(user.id, req.params.id);
  if (!t) return res.status(404).json({ error: 'Todo not found' });
  return res.status(200).json(publicTodo(t));
});

// PUT /todos/:id (partial update)
app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  setJson(res);
  const user = (req as any).user as User;
  const t = findOwnTodo(user.id, req.params.id);
  if (!t) return res.status(404).json({ error: 'Todo not found' });
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      return res.status(400).json({ error: 'Title is required' });
    }
    t.title = title;
  }
  if (description !== undefined) {
    if (typeof description !== 'string') {
      // Reject non-string descriptions
      return res.status(400).json({ error: 'Invalid request body' });
    }
    t.description = description;
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      return res.status(400).json({ error: 'Invalid request body' });
    }
    t.completed = completed;
  }
  t.updated_at = jsonTimeNow();
  return res.status(200).json(publicTodo(t));
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as User;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    // error case: return JSON error per spec
    setJson(res);
    return res.status(404).json({ error: 'Todo not found' });
  }
  const idx = todos.findIndex(td => td.id === id && td.user_id === user.id);
  if (idx === -1) {
    setJson(res);
    return res.status(404).json({ error: 'Todo not found' });
  }
  todos.splice(idx, 1);
  // 204 No Content, no body, and no Content-Type header requirement
  return res.status(204).end();
});

// Error handling to ensure JSON content-type for errors
app.use((err: any, req: Request, res: Response, next: NextFunction) => {
  try {
    setJson(res);
  } catch {}
  const status = typeof err?.status === 'number' && err.status >= 400 && err.status < 600 ? err.status : 500;
  const message = typeof err?.message === 'string' ? err.message : 'Internal Server Error';
  res.status(status).json({ error: message });
});

// Start server
function start() {
  const argv = process.argv.slice(2);
  let port: number | undefined;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port' && i + 1 < argv.length) {
      const p = Number(argv[i + 1]);
      if (Number.isInteger(p) && p > 0 && p < 65536) {
        port = p;
        i++;
      }
    }
  }
  if (!port) {
    console.error('Usage: node dist/server.js --port PORT');
    process.exit(1);
  }
  app.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

if (require.main === module) {
  start();
}

export default app;
