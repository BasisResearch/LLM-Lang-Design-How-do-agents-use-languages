import express, { NextFunction, Request, Response } from 'express';
import cookieParser from 'cookie-parser';
import crypto from 'crypto';

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
const usernameToUserId = new Map<string, number>();
const sessions = new Map<string, number>(); // session_id -> userId
const todos: Todo[] = [];

let nextUserId = 1;
let nextTodoId = 1;

// Utilities
function isoNow(): string {
  const d = new Date();
  // Second precision UTC
  const yyyy = d.getUTCFullYear();
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  const hh = String(d.getUTCHours()).padStart(2, '0');
  const mi = String(d.getUTCMinutes()).padStart(2, '0');
  const ss = String(d.getUTCSeconds()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}T${hh}:${mi}:${ss}Z`;
}

function hashPassword(pw: string): string {
  // Simple but deterministic hashing; not for production security
  return crypto.createHash('sha256').update(pw, 'utf8').digest('hex');
}

function generateToken(): string {
  return crypto.randomBytes(16).toString('hex');
}

function json(res: Response, status: number, body: any) {
  res.statusCode = status; // avoid express helpers that might adjust headers
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(body));
}

// Express app
const app = express();
app.use(express.json());
app.use(cookieParser());

// Auth middleware
function requireAuth(req: Request, res: Response, next: NextFunction) {
  const token = req.cookies?.['session_id'];
  if (!token) {
    json(res, 401, { error: 'Authentication required' });
    return;
  }
  const userId = sessions.get(token);
  if (!userId) {
    json(res, 401, { error: 'Authentication required' });
    return;
  }
  (req as any).userId = userId;
  (req as any).sessionToken = token;
  next();
}

function publicUser(user: User) {
  return { id: user.id, username: user.username };
}

function validateUsername(username: any): username is string {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

// Routes
// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (!validateUsername(username)) {
    json(res, 400, { error: 'Invalid username' });
    return;
  }
  if (typeof password !== 'string' || password.length < 8) {
    json(res, 400, { error: 'Password too short' });
    return;
  }
  if (usernameToUserId.has(username)) {
    json(res, 409, { error: 'Username already exists' });
    return;
  }
  const user: User = { id: nextUserId++, username, passwordHash: hashPassword(password) };
  users.push(user);
  usernameToUserId.set(username, user.id);
  json(res, 201, publicUser(user));
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || typeof password !== 'string') {
    json(res, 401, { error: 'Invalid credentials' });
    return;
  }
  const uid = usernameToUserId.get(username);
  if (!uid) {
    json(res, 401, { error: 'Invalid credentials' });
    return;
  }
  const user = users.find(u => u.id === uid)!;
  if (user.passwordHash !== hashPassword(password)) {
    json(res, 401, { error: 'Invalid credentials' });
    return;
  }
  const token = generateToken();
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  json(res, 200, publicUser(user));
});

// POST /logout
app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token = (req as any).sessionToken as string;
  if (token) {
    sessions.delete(token);
  }
  json(res, 200, {});
});

// GET /me
app.get('/me', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = users.find(u => u.id === userId)!;
  json(res, 200, publicUser(user));
});

// HEAD /me
app.head('/me', requireAuth, (req: Request, res: Response) => {
  res.setHeader('X-Route', 'head');
  res.setHeader('Content-Type', 'application/json');
  res.statusCode = 200;
  res.end();
});

// PUT /password
app.put('/password', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const { old_password, new_password } = req.body || {};
  const user = users.find(u => u.id === userId)!;
  if (typeof old_password !== 'string' || user.passwordHash !== hashPassword(old_password)) {
    json(res, 401, { error: 'Invalid credentials' });
    return;
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    json(res, 400, { error: 'Password too short' });
    return;
  }
  user.passwordHash = hashPassword(new_password);
  json(res, 200, {});
});

// GET /todos
app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const userTodos = todos.filter(t => t.userId === userId).sort((a, b) => a.id - b.id);
  const result = userTodos.map(({ userId: _uid, ...rest }) => rest);
  json(res, 200, result);
});

// POST /todos
app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    json(res, 400, { error: 'Title is required' });
    return;
  }
  const desc: string = typeof description === 'string' ? description : '';
  const now = isoNow();
  const todo: Todo = {
    id: nextTodoId++,
    userId,
    title,
    description: desc,
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.push(todo);
  const { userId: _uid, ...publicTodo } = todo;
  json(res, 201, publicTodo);
});

function findOwnTodo(userId: number, idParam: string | undefined): Todo | undefined {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) return undefined;
  const t = todos.find(td => td.id === id);
  if (!t) return undefined;
  if (t.userId !== userId) return undefined; // conceal existence
  return t;
}

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = findOwnTodo(userId, req.params.id);
  if (!t) {
    json(res, 404, { error: 'Todo not found' });
    return;
  }
  const { userId: _uid, ...publicTodo } = t;
  json(res, 200, publicTodo);
});

// PUT /todos/:id (partial update)
app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = findOwnTodo(userId, req.params.id);
  if (!t) {
    json(res, 404, { error: 'Todo not found' });
    return;
  }
  const body = req.body || {};
  if (Object.prototype.hasOwnProperty.call(body, 'title')) {
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      json(res, 400, { error: 'Title is required' });
      return;
    }
    t.title = body.title;
  }
  if (Object.prototype.hasOwnProperty.call(body, 'description')) {
    if (typeof body.description !== 'string') {
      json(res, 400, { error: 'Invalid description' });
      return;
    }
    t.description = body.description;
  }
  if (Object.prototype.hasOwnProperty.call(body, 'completed')) {
    if (typeof body.completed !== 'boolean') {
      json(res, 400, { error: 'Invalid completed' });
      return;
    }
    t.completed = body.completed;
  }
  t.updated_at = isoNow();
  const { userId: _uid, ...publicTodo } = t;
  json(res, 200, publicTodo);
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    json(res, 404, { error: 'Todo not found' });
    return;
  }
  const idx = todos.findIndex(td => td.id === id);
  if (idx === -1 || todos[idx].userId !== userId) {
    json(res, 404, { error: 'Todo not found' });
    return;
  }
  todos.splice(idx, 1);
  // per spec: 204 (no body)
  res.statusCode = 204;
  res.end();
});

// Error handler to ensure JSON errors
app.use((err: any, req: Request, res: Response, next: NextFunction) => {
  console.error('Unhandled error:', err);
  if (!res.headersSent) {
    res.statusCode = 500;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ error: 'Internal server error' }));
  } else {
    next(err);
  }
});

// Start server
function start() {
  const args = process.argv.slice(2);
  let port: number | undefined;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port' && i + 1 < args.length) {
      const p = Number(args[i + 1]);
      if (Number.isInteger(p) && p > 0 && p < 65536) {
        port = p;
        i++;
      }
    }
  }
  if (!port) {
    console.error('Usage: node server.js --port PORT');
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
