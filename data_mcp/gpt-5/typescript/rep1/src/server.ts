import express, { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';
import http from 'http';

// Types
interface User {
  id: number;
  username: string;
  passwordHash: string; // simple hash in-memory
}

interface Todo {
  id: number;
  userId: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string; // ISO8601 UTC seconds
  updated_at: string; // ISO8601 UTC seconds
}

// In-memory stores
const users: User[] = [];
const usernameToUserId = new Map<string, number>();
let nextUserId = 1;

const todos: Todo[] = [];
let nextTodoId = 1;

// Sessions: token -> userId
const sessions = new Map<string, number>();

// Helpers
function hashPassword(pw: string): string {
  // Using sha256 for demo; in-memory only
  return crypto.createHash('sha256').update(pw).digest('hex');
}

function genToken(): string {
  return crypto.randomBytes(16).toString('hex');
}

function isoNow(): string {
  // ISO8601 UTC with seconds precision and Z
  const d = new Date();
  const iso = d.toISOString(); // e.g., 2025-01-15T09:30:00.123Z
  // Truncate milliseconds
  return iso.replace(/\.\d{3}Z$/, 'Z');
}

// Express app
const app = express();
app.use(express.json());

// Enforce Content-Type: application/json on all responses (except 204 which has no body)
app.use((req: Request, res: Response, next: NextFunction) => {
  res.setHeader('Content-Type', 'application/json');
  next();
});

// Cookie parsing (only need session_id)
function parseCookies(cookieHeader: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!cookieHeader) return out;
  const parts = cookieHeader.split(';');
  for (const p of parts) {
    const [k, v] = p.split('=');
    if (!k) continue;
    const key = k.trim();
    const val = (v ?? '').trim();
    out[key] = decodeURIComponent(val);
  }
  return out;
}

// Auth middleware
function requireAuth(req: Request, res: Response, next: NextFunction) {
  const cookies = parseCookies(req.headers['cookie'] as string | undefined);
  const token = cookies['session_id'];
  if (!token || !sessions.has(token)) {
    res.status(401).json({ error: 'Authentication required' });
    return;
  }
  const userId = sessions.get(token)!;
  // Attach to req
  (req as any).userId = userId;
  (req as any).sessionToken = token;
  next();
}

// Validators
const USERNAME_RE = /^[a-zA-Z0-9_]{3,50}$/;

// Routes
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
  if (usernameToUserId.has(username)) {
    res.status(409).json({ error: 'Username already exists' });
    return;
  }
  const user: User = {
    id: nextUserId++,
    username,
    passwordHash: hashPassword(password),
  };
  users.push(user);
  usernameToUserId.set(username, user.id);
  res.status(201).json({ id: user.id, username: user.username });
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || typeof password !== 'string') {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  const uid = usernameToUserId.get(username);
  if (!uid) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  const user = users.find(u => u.id === uid)!;
  if (user.passwordHash !== hashPassword(password)) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  // Create session
  const token = genToken();
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token: string = (req as any).sessionToken;
  sessions.delete(token);
  res.status(200).json({});
});

app.get('/me', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = users.find(u => u.id === userId)!;
  res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || typeof new_password !== 'string') {
    res.status(400).json({ error: 'Password too short' });
    return;
  }
  const user = users.find(u => u.id === userId)!;
  if (user.passwordHash !== hashPassword(old_password)) {
    res.status(401).json({ error: 'Invalid credentials' });
    return;
  }
  if (new_password.length < 8) {
    res.status(400).json({ error: 'Password too short' });
    return;
  }
  user.passwordHash = hashPassword(new_password);
  res.status(200).json({});
});

app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const list = todos.filter(t => t.userId === userId).sort((a, b) => a.id - b.id);
  res.status(200).json(list.map(({ userId: _u, ...rest }) => rest));
});

app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    res.status(400).json({ error: 'Title is required' });
    return;
  }
  const now = isoNow();
  const todo: Todo = {
    id: nextTodoId++,
    userId,
    title: title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.push(todo);
  const { userId: _u, ...publicTodo } = todo;
  res.status(201).json(publicTodo);
});

function findOwnTodo(userId: number, idParam: string): Todo | undefined {
  const id = Number(idParam);
  if (!Number.isInteger(id)) return undefined;
  const t = todos.find(tt => tt.id === id && tt.userId === userId);
  return t;
}

app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = findOwnTodo(userId, req.params.id);
  if (!t) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  const { userId: _u, ...publicTodo } = t;
  res.status(200).json(publicTodo);
});

app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = findOwnTodo(userId, req.params.id);
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
      res.status(400).json({ error: 'Invalid request' });
      return;
    }
    t.description = description;
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      res.status(400).json({ error: 'Invalid request' });
      return;
    }
    t.completed = completed;
  }
  t.updated_at = isoNow();
  const { userId: _u, ...publicTodo } = t;
  res.status(200).json(publicTodo);
});

app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const id = Number(req.params.id);
  if (!Number.isInteger(id)) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  const idx = todos.findIndex(t => t.id === id && t.userId === userId);
  if (idx === -1) {
    res.status(404).json({ error: 'Todo not found' });
    return;
  }
  todos.splice(idx, 1);
  res.status(204).end();
});

// Error handler to ensure JSON error format
app.use((err: any, req: Request, res: Response, next: NextFunction) => {
  try {
    if (res.headersSent) return next(err);
    res.status(500).json({ error: 'Internal server error' });
  } catch {
    next(err);
  }
});

// Server startup
function start(port: number) {
  const server: http.Server = app.listen(port, '0.0.0.0', () => {
    const addr = server.address();
    const actualPort = typeof addr === 'object' && addr ? addr.port : port;
    console.log(`Server listening on 0.0.0.0:${actualPort}`);
  });
}

// CLI parsing for --port
if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  let port = 3000;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
      const p = Number(args[i + 1]);
      if (!Number.isFinite(p) || p < 0 || p >= 65536) {
        console.error('Invalid port');
        process.exit(1);
      }
      port = p;
      i++;
    }
  }
  start(port);
}

export default app;
