import express, { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';

// Utility to format ISO 8601 UTC with second precision
function nowIsoSeconds(): string {
  const d = new Date();
  // toISOString returns ms precision; strip milliseconds
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

// Types
interface User {
  id: number;
  username: string;
  passwordHash: string; // store hashed password in memory
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
let nextUserId = 1;

const todos: Todo[] = [];
let nextTodoId = 1;

// session token => userId
const sessions = new Map<string, number>();

// Simple password hashing (not for production) using sha256 to avoid storing plaintext
function hashPassword(pw: string): string {
  return crypto.createHash('sha256').update(pw).digest('hex');
}

// Middleware to ensure JSON Content-Type for all responses
function jsonContentType(_req: Request, res: Response, next: NextFunction) {
  // For DELETE 204, we'll explicitly not send body later.
  res.setHeader('Content-Type', 'application/json');
  next();
}

// Cookie parser for session_id only (avoid extra dependency)
function parseCookies(header: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!header) return out;
  const parts = header.split(';');
  for (const p of parts) {
    const idx = p.indexOf('=');
    if (idx === -1) continue;
    const key = p.slice(0, idx).trim();
    const val = p.slice(idx + 1).trim();
    out[key] = decodeURIComponent(val);
  }
  return out;
}

// Auth middleware
interface AuthedRequest extends Request {
  user?: User;
}

function requireAuth(req: AuthedRequest, res: Response, next: NextFunction) {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (!token) {
    res.status(401).json({ error: 'Authentication required' });
    return;
  }
  const userId = sessions.get(token);
  if (!userId) {
    res.status(401).json({ error: 'Authentication required' });
    return;
  }
  const user = users.find(u => u.id === userId);
  if (!user) {
    // session references non-existing user; invalidate
    sessions.delete(token);
    res.status(401).json({ error: 'Authentication required' });
    return;
  }
  req.user = user;
  next();
}

const app = express();
app.disable('x-powered-by');
app.use(express.json());
app.use(jsonContentType);

// Handle JSON parse errors from express.json to return JSON error format
app.use((err: any, _req: Request, res: Response, next: NextFunction) => {
  if (err && err.type === 'entity.parse.failed') {
    res.status(400).json({ error: 'Invalid JSON' });
    return;
  }
  next(err);
});

// Health endpoint for readiness
app.get('/health', (_req, res) => {
  res.status(200).json({});
});

// Helper to validate usernames
const USERNAME_RE = /^[a-zA-Z0-9_]{3,50}$/;

// Endpoints
// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || !USERNAME_RE.test(username)) {
    res.status(400).json({ error: 'Invalid username' });
    return;
  }
  if (typeof password !== 'string' || password.length < 8) {
    res.status(400).json({ error: 'Password too short' });
    return;
  }
  if (users.some(u => u.username === username)) {
    res.status(409).json({ error: 'Username already exists' });
    return;
  }
  const user: User = {
    id: nextUserId++,
    username,
    passwordHash: hashPassword(password),
  };
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
  if (!user || user.passwordHash !== hashPassword(password)) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  // Generate session token
  const token = crypto.randomBytes(16).toString('hex');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.status(200).json({ id: user.id, username: user.username });
});

// POST /logout
app.post('/logout', requireAuth, (req: AuthedRequest, res: Response) => {
  const cookies = parseCookies(req.headers['cookie']);
  const token = cookies['session_id'];
  if (token) {
    sessions.delete(token);
  }
  res.status(200).json({});
});

// GET /me
app.get('/me', requireAuth, (req: AuthedRequest, res: Response) => {
  const user = req.user!;
  res.status(200).json({ id: user.id, username: user.username });
});

// PUT /password
app.put('/password', requireAuth, (req: AuthedRequest, res: Response) => {
  const user = req.user!;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || hashPassword(old_password) !== user.passwordHash) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    res.status(400).json({ error: 'Password too short' });
    return;
  }
  user.passwordHash = hashPassword(new_password);
  res.status(200).json({});
});

// GET /todos
app.get('/todos', requireAuth, (req: AuthedRequest, res: Response) => {
  const user = req.user!;
  const list = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id);
  res.status(200).json(list.map(({ userId, ...rest }) => rest));
});

// POST /todos
app.post('/todos', requireAuth, (req: AuthedRequest, res: Response) => {
  const user = req.user!;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    res.status(400).json({ error: 'Title is required' });
    return;
  }
  const desc = typeof description === 'string' ? description : '';
  const ts = nowIsoSeconds();
  const todo: Todo = {
    id: nextTodoId++,
    userId: user.id,
    title,
    description: desc,
    completed: false,
    created_at: ts,
    updated_at: ts,
  };
  todos.push(todo);
  const { userId, ...publicTodo } = todo;
  res.status(201).json(publicTodo);
});

function findOwnTodo(userId: number, idParam: string): Todo | undefined {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) return undefined;
  const t = todos.find(tt => tt.id === id);
  if (!t || t.userId !== userId) return undefined;
  return t;
}

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req: AuthedRequest, res: Response) => {
  const user = req.user!;
  const t = findOwnTodo(user.id, req.params.id);
  if (!t) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  const { userId, ...publicTodo } = t;
  res.status(200).json(publicTodo);
});

// PUT /todos/:id (partial update)
app.put('/todos/:id', requireAuth, (req: AuthedRequest, res: Response) => {
  const user = req.user!;
  const t = findOwnTodo(user.id, req.params.id);
  if (!t) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      res.status(400).json({ error: 'Title is required' });
      return;
    }
    t.title = title;
  }
  if (description !== undefined) {
    if (typeof description !== 'string') {
      t.description = String(description);
    } else {
      t.description = description;
    }
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      res.status(400).json({ error: 'Invalid request' });
      return;
    }
    t.completed = completed;
  }
  t.updated_at = nowIsoSeconds();
  const { userId, ...publicTodo } = t;
  res.status(200).json(publicTodo);
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req: AuthedRequest, res: Response) => {
  const user = req.user!;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  const idx = todos.findIndex(tt => tt.id === id && tt.userId === user.id);
  if (idx === -1) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  todos.splice(idx, 1);
  // 204 No Content with no body
  res.status(204);
  // Must not send Content-Type for 204
  res.removeHeader('Content-Type');
  res.end();
});

// Error handler to ensure JSON error format
app.use((err: any, _req: Request, res: Response, _next: NextFunction) => {
  console.error('Unhandled error:', err);
  if (!res.headersSent) {
    res.status(500).json({ error: 'Internal server error' });
  }
});

function parseArgsPort(): number {
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port' && i + 1 < argv.length) {
      const p = Number(argv[i + 1]);
      if (Number.isInteger(p) && p > 0 && p < 65536) return p;
    }
  }
  return 3000;
}

const port = parseArgsPort();
app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
