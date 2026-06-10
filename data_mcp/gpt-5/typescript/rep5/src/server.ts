import express, { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';

// Utilities
function setJsonContentType(res: Response) {
  // Force exact header without charset
  res.setHeader('Content-Type', 'application/json');
}

function nowIsoSeconds(): string {
  const d = new Date();
  const iso = d.toISOString();
  return iso.replace(/\..+Z$/, 'Z');
}

function generateToken(): string {
  return crypto.randomBytes(16).toString('hex');
}

function parseCookies(req: Request): Record<string, string> {
  const header = req.headers['cookie'];
  const out: Record<string, string> = {};
  if (!header) return out;
  const parts = header.split(';');
  for (const p of parts) {
    const [k, ...rest] = p.trim().split('=');
    const v = rest.join('=');
    if (k) out[k] = v;
  }
  return out;
}

// Types
interface User {
  id: number;
  username: string;
  passwordHash: string;
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
const usernames = new Map<string, User>();
let nextUserId = 1;

const todos: Todo[] = [];
let nextTodoId = 1;

// session token -> userId
const sessions = new Map<string, number>();

function hashPassword(pw: string): string {
  return crypto.createHash('sha256').update(pw).digest('hex');
}

// Express setup
const app = express();

// JSON body parser
app.use(express.json({ type: ['application/json', 'text/json', '*/json'] }));

// Middleware to enforce Content-Type and stable json responses
app.use((req, res, next) => {
  // Patch res.json to avoid Express adding charset; use res.end directly
  const origEnd = res.end.bind(res);
  (res as any).json = (body: any) => {
    try {
      setJsonContentType(res);
      const payload = typeof body === 'string' ? body : JSON.stringify(body);
      origEnd(payload);
    } catch (e) {
      // Fallback
      try { origEnd(''); } catch {}
    }
    return res;
  };
  // Default header for all non-DELETE responses
  if (req.method !== 'DELETE') {
    setJsonContentType(res);
  }
  next();
});

// Auth middleware
function requireAuth(req: Request, res: Response, next: NextFunction) {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  const userId = sessions.get(token);
  if (!userId) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  (req as any).userId = userId;
  (req as any).sessionToken = token;
  next();
}

function publicUser(u: User) {
  return { id: u.id, username: u.username };
}

// Endpoints
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || username.length < 3 || username.length > 50 || !/^[_a-zA-Z0-9]+$/.test(username)) {
    return res.status(400).json({ error: 'Invalid username' });
  }
  if (typeof password !== 'string' || password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  if (usernames.has(username)) {
    return res.status(409).json({ error: 'Username already exists' });
  }
  const user: User = {
    id: nextUserId++,
    username,
    passwordHash: hashPassword(password),
  };
  users.push(user);
  usernames.set(username, user);
  return res.status(201).json(publicUser(user));
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || typeof password !== 'string') {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  const user = usernames.get(username);
  if (!user || user.passwordHash !== hashPassword(password)) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  const token = generateToken();
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  return res.status(200).json(publicUser(user));
});

app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token: string = (req as any).sessionToken;
  if (token) {
    sessions.delete(token);
  }
  return res.status(200).json({});
});

app.get('/me', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = users.find(u => u.id === userId);
  if (!user) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  return res.status(200).json(publicUser(user));
});

app.put('/password', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = users.find(u => u.id === userId);
  if (!user) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || user.passwordHash !== hashPassword(old_password)) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return res.status(400).json({ error: 'Password too short' });
  }
  user.passwordHash = hashPassword(new_password);
  return res.status(200).json({});
});

app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const list = todos.filter(t => t.userId === userId).sort((a, b) => a.id - b.id);
  return res.status(200).json(list.map(stripOwner));
});

function stripOwner(t: Todo) {
  const { userId, ...rest } = t as any;
  return rest;
}

app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  let { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim().length === 0) {
    return res.status(400).json({ error: 'Title is required' });
  }
  title = title.trim();
  if (typeof description !== 'string') description = '';
  const ts = nowIsoSeconds();
  const todo: Todo = {
    id: nextTodoId++,
    userId,
    title,
    description,
    completed: false,
    created_at: ts,
    updated_at: ts,
  };
  todos.push(todo);
  return res.status(201).json(stripOwner(todo));
});

function findUserTodoById(userId: number, idStr: string): Todo | undefined {
  const id = Number(idStr);
  if (!Number.isInteger(id) || id <= 0) return undefined;
  const t = todos.find(t => t.id === id);
  if (!t) return undefined;
  if (t.userId !== userId) return undefined;
  return t;
}

app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = findUserTodoById(userId, req.params.id);
  if (!t) return res.status(404).json({ error: 'Todo not found' });
  return res.status(200).json(stripOwner(t));
});

app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = findUserTodoById(userId, req.params.id);
  if (!t) return res.status(404).json({ error: 'Todo not found' });

  const body = req.body || {};
  if ('title' in body) {
    if (typeof body.title !== 'string' || body.title.trim().length === 0) {
      return res.status(400).json({ error: 'Title is required' });
    }
    t.title = body.title.trim();
  }
  if ('description' in body) {
    if (typeof body.description !== 'string') {
      t.description = '';
    } else {
      t.description = body.description;
    }
  }
  if ('completed' in body) {
    if (typeof body.completed !== 'boolean') {
      return res.status(400).json({ error: 'Invalid request' });
    }
    t.completed = body.completed;
  }
  t.updated_at = nowIsoSeconds();
  return res.status(200).json(stripOwner(t));
});

app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    return res.status(404).json({ error: 'Todo not found' });
  }
  const idx = todos.findIndex(t => t.id === id && t.userId === userId);
  if (idx === -1) return res.status(404).json({ error: 'Todo not found' });
  todos.splice(idx, 1);
  res.status(204);
  res.removeHeader('Content-Type');
  return res.end();
});

// Error handling (ensure JSON)
app.use((err: any, _req: Request, res: Response, next: NextFunction) => {
  try {
    console.error('Internal error:', err);
  } catch {}
  if (res.headersSent) return next(err);
  return res.status(500).json({ error: 'Internal server error' });
});

// Start server
function start(port: number) {
  const server = app.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
  return server;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  let port = 3000;
  for (let i = 2; i < process.argv.length; i++) {
    if (process.argv[i] === '--port' && i + 1 < process.argv.length) {
      const p = Number(process.argv[i + 1]);
      if (Number.isFinite(p) && p > 0) port = p;
    }
  }
  start(port);
}

export { app, start };
