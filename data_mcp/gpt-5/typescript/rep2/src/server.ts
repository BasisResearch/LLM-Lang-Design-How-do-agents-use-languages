import express, { Request, Response, NextFunction } from 'express';
import cookieParser from 'cookie-parser';
import { v4 as uuidv4 } from 'uuid';

// Types
interface User { id: number; username: string; }
interface UserRecord extends User { password: string; }
interface Todo {
  id: number;
  user_id: number;
  title: string;
  description: string;
  completed: boolean;
  created_at: string; // ISO 8601 UTC with seconds precision
  updated_at: string;
}

// In-memory storage
const users: UserRecord[] = [];
const sessions = new Map<string, number>(); // session_id -> user_id
const todos: Todo[] = [];
let nextUserId = 1;
let nextTodoId = 1;

// Helpers
function nowIsoSeconds(): string {
  const d = new Date();
  // Ensure seconds precision and Z
  const iso = d.toISOString(); // e.g., 2025-01-15T09:30:00.123Z
  return iso.replace(/\..+Z$/, 'Z');
}

function json(res: Response, status: number, body: any) {
  // Force exact content-type without charset and avoid express res.send which may append charset
  res.status(status);
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(body));
}

function error(res: Response, status: number, message: string) {
  json(res, status, { error: message });
}

function parsePortArg(): number | null {
  const idx = process.argv.indexOf('--port');
  if (idx !== -1 && process.argv[idx + 1]) {
    const p = Number(process.argv[idx + 1]);
    if (Number.isInteger(p) && p > 0 && p < 65536) return p;
  }
  return null;
}

function findUserByUsername(username: string): UserRecord | undefined {
  return users.find(u => u.username === username);
}

function requireAuth(req: Request, res: Response, next: NextFunction) {
  const token = req.cookies?.['session_id'];
  if (!token || !sessions.has(token)) {
    return error(res, 401, 'Authentication required');
  }
  const userId = sessions.get(token)!;
  const user = users.find(u => u.id === userId);
  if (!user) {
    // Stale session token pointing to non-existent user
    sessions.delete(token);
    return error(res, 401, 'Authentication required');
  }
  (req as any).user = user;
  (req as any).sessionToken = token;
  next();
}

const app = express();
app.use(express.json());
app.use(cookieParser());

// Routes
// POST /register
app.post('/register', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  if (typeof username !== 'string' || username.length < 3 || username.length > 50 || !/^[a-zA-Z0-9_]+$/.test(username)) {
    return error(res, 400, 'Invalid username');
  }
  if (typeof password !== 'string' || password.length < 8) {
    return error(res, 400, 'Password too short');
  }
  if (findUserByUsername(username)) {
    return error(res, 409, 'Username already exists');
  }
  const user: UserRecord = { id: nextUserId++, username, password };
  users.push(user);
  const publicUser: User = { id: user.id, username: user.username };
  return json(res, 201, publicUser);
});

// POST /login
app.post('/login', (req: Request, res: Response) => {
  const { username, password } = req.body || {};
  const user = findUserByUsername(username);
  if (!user || user.password !== password) {
    return error(res, 401, 'Invalid credentials');
  }
  const token = uuidv4().replace(/-/g, '');
  sessions.set(token, user.id);
  res.setHeader('Set-Cookie', `session_id=${token}; Path=/; HttpOnly`);
  return json(res, 200, { id: user.id, username: user.username });
});

// POST /logout
app.post('/logout', requireAuth, (req: Request, res: Response) => {
  const token = (req as any).sessionToken as string;
  if (token) {
    sessions.delete(token);
  }
  return json(res, 200, {});
});

// GET /me
app.get('/me', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as UserRecord;
  return json(res, 200, { id: user.id, username: user.username });
});

// PUT /password
app.put('/password', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as UserRecord;
  const { old_password, new_password } = req.body || {};
  if (typeof old_password !== 'string' || user.password !== old_password) {
    return error(res, 401, 'Invalid credentials');
  }
  if (typeof new_password !== 'string' || new_password.length < 8) {
    return error(res, 400, 'Password too short');
  }
  user.password = new_password;
  return json(res, 200, {});
});

// GET /todos
app.get('/todos', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as UserRecord;
  const userTodos = todos.filter(t => t.user_id === user.id).sort((a, b) => a.id - b.id);
  const result = userTodos.map(({ user_id, ...rest }) => rest);
  return json(res, 200, result);
});

// POST /todos
app.post('/todos', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as UserRecord;
  const { title, description } = req.body || {};
  if (typeof title !== 'string' || title.trim() === '') {
    return error(res, 400, 'Title is required');
  }
  const now = nowIsoSeconds();
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
  const { user_id, ...publicTodo } = todo;
  return json(res, 201, publicTodo);
});

function getTodoForUserOr404(idParam: string, userId: number, res: Response): Todo | null {
  const id = Number(idParam);
  if (!Number.isInteger(id) || id <= 0) {
    error(res, 404, 'Todo not found');
    return null;
  }
  const todo = todos.find(t => t.id === id && t.user_id === userId);
  if (!todo) {
    error(res, 404, 'Todo not found');
    return null;
  }
  return todo;
}

// GET /todos/:id
app.get('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as UserRecord;
  const todo = getTodoForUserOr404(req.params.id, user.id, res);
  if (!todo) return;
  const { user_id, ...publicTodo } = todo;
  return json(res, 200, publicTodo);
});

// PUT /todos/:id
app.put('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as UserRecord;
  const todo = getTodoForUserOr404(req.params.id, user.id, res);
  if (!todo) return;
  const { title, description, completed } = req.body || {};
  if (title !== undefined) {
    if (typeof title !== 'string' || title.trim() === '') {
      return error(res, 400, 'Title is required');
    }
    todo.title = title;
  }
  if (description !== undefined) {
    if (typeof description !== 'string') {
      // If provided but not string, reject per strict typing
      return error(res, 400, 'Invalid description');
    }
    todo.description = description;
  }
  if (completed !== undefined) {
    if (typeof completed !== 'boolean') {
      return error(res, 400, 'Invalid completed');
    }
    todo.completed = completed;
  }
  todo.updated_at = nowIsoSeconds();
  const { user_id, ...publicTodo } = todo;
  return json(res, 200, publicTodo);
});

// DELETE /todos/:id
app.delete('/todos/:id', requireAuth, (req: Request, res: Response) => {
  const user = (req as any).user as UserRecord;
  const id = Number(req.params.id);
  const idx = todos.findIndex(t => t.id === id && t.user_id === user.id);
  if (!Number.isInteger(id) || id <= 0 || idx === -1) {
    return error(res, 404, 'Todo not found');
  }
  todos.splice(idx, 1);
  res.status(204);
  // No body and no content-type requirement per spec for DELETE
  return res.end();
});

// 404 fallback
app.use((req, res) => {
  error(res, 404, 'Not found');
});

export function startServer(port: number) {
  app.listen(port, '0.0.0.0', () => {
    console.log(`Server listening on 0.0.0.0:${port}`);
  });
}

if (process.argv.includes('--port')) {
  const port = parsePortArg() ?? 3000;
  startServer(port);
}
