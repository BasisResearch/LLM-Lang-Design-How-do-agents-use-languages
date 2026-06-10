import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { v4 as uuidv4 } from 'uuid';

// Types
interface User {
  id: number;
  username: string;
  password: string; // stored in-memory as plain for this exercise (not for production)
}

interface PublicUser {
  id: number;
  username: string;
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

// In-memory storage
const users: User[] = [];
const todos: Todo[] = [];
let nextUserId = 1;
let nextTodoId = 1;

// session store: token -> userId
const sessions = new Map<string, number>();

// Helpers
function jsonTimestampNow(): string {
  // ISO 8601 UTC with seconds precision, e.g., 2025-01-15T09:30:00Z
  const d = new Date();
  const iso = d.toISOString(); // e.g., 2025-01-15T09:30:00.123Z
  return iso.replace(/\.\d{3}Z$/, 'Z');
}

function sendJson(res: Response, status: number, body: any) {
  res.status(status);
  res.setHeader('Content-Type', 'application/json');
  if (status === 204) {
    // no body for 204
    return res.end();
  }
  return res.send(JSON.stringify(body));
}

function error(res: Response, status: number, message: string) {
  return sendJson(res, status, { error: message });
}

function validateUsername(username: unknown): username is string {
  if (typeof username !== 'string') return false;
  if (username.length < 3 || username.length > 50) return false;
  if (!/^[a-zA-Z0-9_]+$/.test(username)) return false;
  return true;
}

function requireAuth(req: Request, res: Response, next: NextFunction) {
  const token = req.cookies?.['session_id'];
  if (!token) {
    return error(res, 401, 'Authentication required');
  }
  const userId = sessions.get(token);
  if (!userId) {
    return error(res, 401, 'Authentication required');
  }
  // attach userId to request
  (req as any).userId = userId;
  (req as any).sessionToken = token;
  next();
}

function publicUser(u: User): PublicUser {
  return { id: u.id, username: u.username };
}

function getUserByUsername(username: string): User | undefined {
  return users.find(u => u.username === username);
}

function getUserById(id: number): User | undefined {
  return users.find(u => u.id === id);
}

const app = express();
app.use(express.json());
app.use(cookieParser());

// Middleware to enforce Content-Type for all JSON responses
app.use((req, res, next) => {
  // We'll set Content-Type in sendJson to be safe.
  next();
});

// Routes
// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};

  if (!validateUsername(username)) {
    return error(res, 400, 'Invalid username');
  }
  if (typeof password !== 'string') {
    return error(res, 400, 'Password too short');
  }
  if (password.length < 8) {
    return error(res, 400, 'Password too short');
  }
  if (getUserByUsername(username)) {
    return error(res, 409, 'Username already exists');
  }

  const newUser: User = { id: nextUserId++, username, password };
  users.push(newUser);
  return sendJson(res, 201, publicUser(newUser));
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = typeof username === 'string' ? getUserByUsername(username) : undefined;
  if (!user || typeof password !== 'string' || user.password !== password) {
    return error(res, 401, 'Invalid credentials');
  }
  const token = uuidv4().replace(/-/g, '');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  return sendJson(res, 200, publicUser(user));
});

// POST /logout
app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token: string | undefined = (req as any).sessionToken;
  if (token) {
    sessions.delete(token);
  }
  return sendJson(res, 200, {});
});

// GET /me
app.get('/me', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = getUserById(userId)!;
  return sendJson(res, 200, publicUser(user));
});

// PUT /password
app.put('/password', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const user = getUserById(userId)!;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || user.password !== old_password) {
    return error(res, 401, 'Invalid credentials');
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return error(res, 400, 'Password too short');
  }
  user.password = new_password;
  return sendJson(res, 200, {});
});

// GET /todos
app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const list = todos.filter(t => t.userId === userId).sort((a, b) => a.id - b.id);
  return sendJson(res, 200, list.map(({ userId: _u, ...rest }) => rest));
});

// POST /todos
app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return error(res, 400, 'Title is required');
  }
  const now = jsonTimestampNow();
  const todo: Todo = {
    id: nextTodoId++,
    userId,
    title,
    description: typeof description === 'string' ? description : '',
    completed: false,
    created_at: now,
    updated_at: now,
  };
  todos.push(todo);
  const { userId: _u, ...publicTodo } = todo;
  return sendJson(res, 201, publicTodo);
});

function findOwnedTodoOr404(idParam: string, userId: number): Todo | undefined {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) return undefined;
  const t = todos.find(td => td.id === id);
  if (!t || t.userId !== userId) return undefined;
  return t;
}

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = findOwnedTodoOr404(req.params.id, userId);
  if (!t) return error(res, 404, 'Todo not found');
  const { userId: _u, ...publicTodo } = t;
  return sendJson(res, 200, publicTodo);
});

// PUT /todos/:id (partial update)
app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const t = findOwnedTodoOr404(req.params.id, userId);
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
      // coerce non-string to string? Spec doesn't say; reject
      return error(res, 400, 'Invalid description');
    }
    t.description = description;
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      return error(res, 400, 'Invalid completed flag');
    }
    t.completed = completed;
  }
  t.updated_at = jsonTimestampNow();
  const { userId: _u, ...publicTodo } = t;
  return sendJson(res, 200, publicTodo);
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const userId: number = (req as any).userId;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) return error(res, 404, 'Todo not found');
  const idx = todos.findIndex(t => t.id === id && t.userId === userId);
  if (idx === -1) return error(res, 404, 'Todo not found');
  todos.splice(idx, 1);
  res.status(204);
  // Per spec: DELETE returns no body and no JSON content-type
  return res.end();
});

// 404 handler for unknown paths: provide JSON error
app.use((req: Request, res: Response) => {
  return error(res, 404, 'Not found');
});

function parsePortArg(): number {
  const args = process.argv.slice(2);
  const idx = args.indexOf('--port');
  if (idx !== -1 && idx + 1 < args.length) {
    const p = Number(args[idx + 1]);
    if (Number.isInteger(p) && p > 0 && p < 65536) {
      return p;
    }
  }
  // default port
  return 3000;
}

const port = parsePortArg();
app.listen(port, '0.0.0.0', () => {
  console.log(`Server listening on 0.0.0.0:${port}`);
});
