import express, { Request, Response, NextFunction } from 'express';
import { v4 as uuidv4 } from 'uuid';

// Types
interface User {
  id: number;
  username: string;
  password: string; // store plaintext for this exercise (in-memory);
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

const sessions = new Map<string, number>(); // session_id -> userId

const todos: Todo[] = [];
let nextTodoId = 1;

// Helpers
function sendJson(res: Response, status: number, body: any) {
  res.status(status);
  // DELETE endpoints return no body and thus no content-type required by spec; all others must be json
  if (status === 204) {
    return res.end();
  }
  res.setHeader('Content-Type', 'application/json');
  res.send(JSON.stringify(body));
}

function error(res: Response, status: number, message: string) {
  return sendJson(res, status, { error: message });
}

function parseCookies(req: Request): Record<string, string> {
  const header = req.headers['cookie'];
  const out: Record<string, string> = {};
  if (!header) return out;
  const parts = header.split(';');
  for (const part of parts) {
    const [k, ...rest] = part.trim().split('=');
    const v = rest.join('=');
    if (k) out[k] = decodeURIComponent(v || '');
  }
  return out;
}

function formatTimestamp(date: Date): string {
  // ISO 8601 UTC timestamp with second precision: YYYY-MM-DDTHH:MM:SSZ
  const iso = date.toISOString();
  return iso.replace(/\.\d{3}Z$/, 'Z');
}

// Middleware to ensure JSON requests and set response content-type by default
const app = express();
app.use(express.json({ type: [
  'application/json',
  'application/*+json'
] as any }));

// Ensure all non-DELETE responses include application/json
app.use((req: Request, res: Response, next: NextFunction) => {
  const oldSend = res.send.bind(res);
  (res as any).send = (body?: any) => {
    if (res.statusCode !== 204) {
      res.setHeader('Content-Type', 'application/json');
    }
    return oldSend(body);
  };
  next();
});

// Error handler to convert body-parser JSON errors into JSON responses
app.use((err: any, _req: Request, res: Response, next: NextFunction) => {
  if (!err) return next();
  // Treat any body parse error as invalid JSON
  return error(res, 400, 'Invalid JSON');
});

function getAuthUser(req: Request): User | null {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (!token) return null;
  const userId = sessions.get(token);
  if (!userId) return null;
  const user = users.find(u => u.id === userId) || null;
  return user;
}

function requireAuth(req: Request, res: Response, next: NextFunction) {
  const user = getAuthUser(req);
  if (!user) return error(res, 401, 'Authentication required');
  (req as any).user = user;
  next();
}

function validateUsername(username: any): username is string {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function validatePassword(password: any): password is string {
  return typeof password === 'string' && password.length >= 8;
}

// Routes
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};

  if (!validateUsername(username)) {
    return error(res, 400, 'Invalid username');
  }
  if (!validatePassword(password)) {
    return error(res, 400, 'Password too short');
  }
  if (users.some(u => u.username === username)) {
    return error(res, 409, 'Username already exists');
  }

  const user: User = { id: nextUserId++, username, password };
  users.push(user);
  return sendJson(res, 201, { id: user.id, username: user.username });
});

app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = users.find(u => u.username === username && u.password === password);
  if (!user) {
    return error(res, 401, 'Invalid credentials');
  }
  const token = uuidv4().replace(/-/g, '');
  sessions.set(token, user.id);
  // Node types expect an array for Set-Cookie
  res.setHeader('Set-Cookie', [`session_id=${encodeURIComponent(token)}; Path=/; HttpOnly`]);
  return sendJson(res, 200, { id: user.id, username: user.username });
});

app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const cookies = parseCookies(req);
  const token = cookies['session_id'];
  if (token) {
    sessions.delete(token);
  }
  return sendJson(res, 200, {});
});

app.get('/me', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  return sendJson(res, 200, { id: user.id, username: user.username });
});

app.put('/password', requireAuth, (req: Request, res: Response) => {
  const { old_password, new_password } = req.body || {};
  const user: User = (req as any).user;
  if (user.password !== old_password) {
    return error(res, 401, 'Invalid credentials');
  }
  if (!validatePassword(new_password)) {
    return error(res, 400, 'Password too short');
  }
  user.password = new_password;
  return sendJson(res, 200, {});
});

app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const list = todos.filter(t => t.userId === user.id).sort((a, b) => a.id - b.id);
  return sendJson(res, 200, list.map(({ userId, ...rest }) => rest));
});

app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return error(res, 400, 'Title is required');
  }
  const now = formatTimestamp(new Date());
  const todo: Todo = {
    id: nextTodoId++,
    userId: user.id,
    title: title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.push(todo);
  const { userId, ...exposed } = todo;
  return sendJson(res, 201, exposed);
});

function findOwnedTodo(userId: number, idParam: string): Todo | null {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) return null;
  const t = todos.find(td => td.id === id);
  if (!t || t.userId !== userId) return null;
  return t;
}

app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const t = findOwnedTodo(user.id, String(req.params.id));
  if (!t) return error(res, 404, 'Todo not found');
  const { userId, ...exposed } = t;
  return sendJson(res, 200, exposed);
});

app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const t = findOwnedTodo(user.id, String(req.params.id));
  if (!t) return error(res, 404, 'Todo not found');

  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      return error(res, 400, 'Title is required');
    }
    t.title = title;
  }
  if (description !== undefined) {
    if (typeof description !== 'string') {
      // If provided but not string, coerce to string to be safe
      t.description = String(description);
    } else {
      t.description = description;
    }
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      return error(res, 400, 'Invalid request body');
    }
    t.completed = completed;
  }
  t.updated_at = formatTimestamp(new Date());
  const { userId, ...exposed } = t;
  return sendJson(res, 200, exposed);
});

app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user: User = (req as any).user;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    return error(res, 404, 'Todo not found');
  }
  const idx = todos.findIndex(td => td.id === id && td.userId === user.id);
  if (idx === -1) return error(res, 404, 'Todo not found');
  todos.splice(idx, 1);
  res.status(204);
  return res.end();
});

// 404 handler for unknown routes - return JSON error
app.use((req: Request, res: Response) => {
  return error(res, 404, 'Not Found');
});

// Server start
function parsePort(argv: string[]): number {
  const idx = argv.indexOf('--port');
  if (idx !== -1 && idx + 1 < argv.length) {
    const p = Number(argv[idx + 1]);
    if (Number.isInteger(p) && p > 0 && p < 65536) return p;
  }
  return 3000;
}

export function startServer(port: number) {
  app.listen(port, '0.0.0.0', () => {
    // eslint-disable-next-line no-console
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

if (process.argv[1] && process.argv[1].endsWith('server.js') || process.argv[1]?.endsWith('server.ts')) {
  const port = parsePort(process.argv.slice(2));
  startServer(port);
}
