import express, { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';

// Types
interface User {
  id: number;
  username: string;
  passwordHash: string; // simple hash for in-memory; not persisted
}

interface Todo {
  id: number;
  userId: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string; // ISO 8601 UTC seconds precision
  updated_at: string;
}

// In-memory storage
const users: User[] = [];
let nextUserId = 1;

const todos: Todo[] = [];
let nextTodoId = 1;

// sessionId -> userId
const sessions = new Map<string, number>();

// Utilities
function isoNowSeconds(): string {
  const d = new Date();
  // toISOString() includes milliseconds; trim to seconds precision
  return d.toISOString().replace(/\..+Z$/, 'Z');
}

function hashPassword(pw: string): string {
  // In-memory simple hash using sha256 for demo; no salt since non-persistent
  return crypto.createHash('sha256').update(pw, 'utf8').digest('hex');
}

function generateToken(): string {
  return crypto.randomBytes(16).toString('hex');
}

// Express setup
const app = express();
app.use(express.json());

// Force JSON Content-Type on all non-DELETE responses
app.use((req: Request, res: Response, next: NextFunction) => {
  // We will set Content-Type for all responses except DELETE 204 with no body
  res.setHeader('Content-Type', 'application/json');
  next();
});

// Cookie parser minimal: parse Cookie header into object
function parseCookies(cookieHeader: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!cookieHeader) return out;
  const parts = cookieHeader.split(';');
  for (const p of parts) {
    const [k, ...rest] = p.split('=');
    const key = k.trim();
    const value = rest.join('=');
    if (!key) continue;
    out[key] = decodeURIComponent(value?.trim() ?? '');
  }
  return out;
}

// Auth middleware
function requireAuth(req: Request, res: Response, next: NextFunction) {
  const cookies = parseCookies(req.header('cookie'));
  const token = cookies['session_id'];
  if (!token) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  const userId = sessions.get(token);
  if (!userId) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  // attach to request
  (req as any).userId = userId;
  (req as any).sessionToken = token;
  next();
}

// Validators
const USERNAME_RE = /^[a-zA-Z0-9_]{3,50}$/;

function findUserByUsername(username: string): User | undefined {
  return users.find(u => u.username === username);
}

// Routes
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || !USERNAME_RE.test(username)) {
    return res.status(400).json({ error: 'Invalid username' });
  }
  if (typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  if (findUserByUsername(username)) {
    return res.status(409).json({ error: 'Username already exists' });
  }
  const user: User = { id: nextUserId++, username, passwordHash: hashPassword(password) };
  users.push(user);
  return res.status(201).json({ id: user.id, username: user.username });
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = typeof username === 'string' ? findUserByUsername(username) : undefined;
  if (!user || typeof password !== 'string' || user.passwordHash !== hashPassword(password)) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  const token = generateToken();
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  return res.status(200).json({ id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token: string | undefined = (req as any).sessionToken;
  if (token) {
    sessions.delete(token);
  }
  return res.status(200).json({});
});

app.get('/me', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = users.find(u => u.id === userId)!;
  return res.status(200).json({ id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = users.find(u => u.id === userId)!;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || hashPassword(old_password) !== user.passwordHash) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  user.passwordHash = hashPassword(new_password);
  return res.status(200).json({});
});

function todoForUser(u: number, t: Todo): boolean { return t.userId === u; }

app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const list = todos.filter(t => todoForUser(userId, t)).sort((a, b) => a.id - b.id);
  return res.status(200).json(list.map(({ userId: _u, ...rest }) => rest));
});

app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return res.status(400).json({ error: 'Title is required' });
  }
  const now = isoNowSeconds();
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
  return res.status(201).json(publicTodo);
});

function getTodoOwnedBy(userId: number, idParam: string): Todo | undefined {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) return undefined;
  const t = todos.find(t => t.id === id);
  if (!t || t.userId !== userId) return undefined;
  return t;
}

app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = getTodoOwnedBy(userId, req.params.id);
  if (!t) return res.status(404).json({ error: 'Todo not found' });
  const { userId: _u, ...publicTodo } = t;
  return res.status(200).json(publicTodo);
});

app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = getTodoOwnedBy(userId, req.params.id);
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
      // coerce to string only if provided as string; else leave unchanged per spec
      // but safer: reject invalid type
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
  t.updated_at = isoNowSeconds();
  const { userId: _u, ...publicTodo } = t;
  return res.status(200).json(publicTodo);
});

app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const idNum = Number(req.params.id);
  if (!Number.isInteger(idNum) || idNum <= 0) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  const idx = todos.findIndex(t => t.id === idNum && t.userId === userId);
  if (idx === -1) return res.status(404).json({ error: 'Todo not found' });
  todos.splice(idx, 1);
  // For DELETE, spec says return 204 and no body, and Content-Type must not be required
  res.status(204);
  // Clear content-type for 204? We'll remove header to be safe
  res.removeHeader('Content-Type');
  return res.end();
});

// Error handling: ensure JSON error format
app.use((err: any, req: Request, res: Response, next: NextFunction) => {
  console.error('Unhandled error', err);
  if (res.headersSent) return next(err);
  return res.status(500).json({ error: 'Internal server error' });
});

function parsePortArg(): number {
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port' && i + 1 < argv.length) {
      const p = Number(argv[i + 1]);
      if (Number.isInteger(p) && p > 0 && p < 65536) return p;
    }
  }
  // default
  return 3000;
}

const port = parsePortArg();
app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
